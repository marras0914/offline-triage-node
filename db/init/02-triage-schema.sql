-- The field-data schema. Written to be re-runnable: install.sh applies this file
-- on every deploy so an existing node picks up schema changes without a wipe.

\connect triage

-- Severity and category are CHECK constraints rather than native ENUM types.
-- Adding a category during a live incident should be one ALTER, not a type
-- migration with a table rewrite.
CREATE TABLE IF NOT EXISTS requests (
    id                BIGSERIAL PRIMARY KEY,
    received_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Intake, exactly as submitted. Never overwritten by anything downstream:
    -- a coordinator must always be able to read what the person actually typed.
    reporter_name     TEXT NOT NULL,
    location_text     TEXT NOT NULL,
    raw_message       TEXT NOT NULL,

    -- AI triage output. The defaults are deliberately the most severe values:
    -- an insert that arrives without a classification lands at the top of the
    -- queue rather than quietly at the bottom.
    severity          TEXT NOT NULL DEFAULT 'Critical'
                      CHECK (severity IN ('Critical', 'Urgent', 'Standard')),
    category          TEXT NOT NULL DEFAULT 'Medical'
                      CHECK (category IN ('Medical', 'Structural', 'Supply')),
    summary           TEXT,
    people_affected   INTEGER CHECK (people_affected IS NULL OR people_affected >= 0),

    -- Set when the model was unreachable, timed out, or returned something
    -- unusable. These rows are triaged by a human, not trusted.
    needs_review      BOOLEAN NOT NULL DEFAULT FALSE,
    triage_error      TEXT,
    triage_model      TEXT,
    triaged_at        TIMESTAMPTZ,

    -- Coordinator workflow.
    status            TEXT NOT NULL DEFAULT 'New'
                      CHECK (status IN ('New', 'Acknowledged', 'Dispatched', 'Resolved', 'Duplicate')),
    assigned_to       TEXT,
    coordinator_notes TEXT,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The queue read: open requests, worst first. Matches active_queue's ordering.
CREATE INDEX IF NOT EXISTS requests_queue_idx
    ON requests (status, severity, received_at);

CREATE INDEX IF NOT EXISTS requests_received_at_idx
    ON requests (received_at DESC);

-- Partial index: the review pile is small and gets checked constantly.
CREATE INDEX IF NOT EXISTS requests_needs_review_idx
    ON requests (received_at) WHERE needs_review;

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS requests_touch_updated_at ON requests;
CREATE TRIGGER requests_touch_updated_at
    BEFORE UPDATE ON requests
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Repeat submissions --------------------------------------------------------
--
-- In a disaster the same household submits three or four times. The instinct is
-- to suppress the repeats, and it is wrong: marking a repeat `Duplicate` takes
-- it out of active_queue, so a household's SECOND and worse emergency would
-- silently vanish. A repeat is not noise, it is usually an escalation.
--
-- So these are *linked*, not suppressed. Every submission stays in the queue and
-- a coordinator sees "one of four from this address" instead of four unrelated
-- rows. Deciding a repeat is genuinely redundant is a human call, made by
-- setting status to 'Duplicate'.
--
-- One narrow exception is safe to automate: byte-identical text inside ten
-- minutes. That carries no new information by definition, and its original is
-- still sitting in the queue, so removing it loses nothing.
--
-- This lives in a trigger rather than in the n8n workflow deliberately. Any
-- insert path gets it — a future LoRa/MQTT bridge, a manual psql insert, a
-- coordinator pasting a phoned-in report — without reimplementing the rule.

-- Keyed on the reporter alone, NOT on reporter + location.
--
-- Location was the obvious second half and it is the wrong choice: it is the
-- unstable field. Someone resubmitting types their own name the same way both
-- times, but describes where they are differently — "4th and Main", then "4th &
-- Main", then "corner of 4th". Including it produced a key that missed almost
-- every real repeat, which is the failure mode that matters here: a false link
-- only adds a slightly misleading count, while a missed link loses the feature.
--
-- Two different households sharing a surname will group. That is tolerable
-- precisely because this links rather than suppresses, and active_queue shows
-- both locations so a coordinator can see they are different. The one automated
-- suppression additionally requires byte-identical message text, which two
-- separate households will not produce.
CREATE OR REPLACE FUNCTION triage_dedupe_key(reporter TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT lower(regexp_replace(
        replace(coalesce(reporter, ''), '&', 'and'),
        '[^[:alnum:]]+', '', 'g'));
$$;

-- The earlier two-argument version, dropped so re-running this file does not
-- leave an overload the trigger could resolve to.
DROP FUNCTION IF EXISTS triage_dedupe_key(TEXT, TEXT);

ALTER TABLE requests ADD COLUMN IF NOT EXISTS dedupe_key   TEXT;
ALTER TABLE requests ADD COLUMN IF NOT EXISTS duplicate_of BIGINT REFERENCES requests(id);

CREATE INDEX IF NOT EXISTS requests_dedupe_idx ON requests (dedupe_key, received_at DESC);

CREATE OR REPLACE FUNCTION link_repeat_submissions() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    cluster_head BIGINT;
BEGIN
    NEW.dedupe_key := triage_dedupe_key(NEW.reporter_name);

    -- An empty key would herd every anonymous submission into one cluster.
    IF NEW.dedupe_key IS NULL OR NEW.dedupe_key = '' THEN
        RETURN NEW;
    END IF;

    -- Point at the head of the cluster, not the row before it, so five
    -- submissions form a star rather than a chain someone has to walk.
    SELECT coalesce(r.duplicate_of, r.id)
      INTO cluster_head
    FROM requests r
    WHERE r.dedupe_key = NEW.dedupe_key
      AND r.received_at > NEW.received_at - interval '6 hours'
    ORDER BY r.received_at
    LIMIT 1;

    IF cluster_head IS NULL THEN
        RETURN NEW;
    END IF;

    NEW.duplicate_of := cluster_head;

    IF EXISTS (
        SELECT 1 FROM requests r
        WHERE r.dedupe_key = NEW.dedupe_key
          AND r.raw_message = NEW.raw_message
          AND r.received_at > NEW.received_at - interval '10 minutes'
    ) THEN
        NEW.status := 'Duplicate';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS requests_link_repeats ON requests;
CREATE TRIGGER requests_link_repeats
    BEFORE INSERT ON requests
    FOR EACH ROW EXECUTE FUNCTION link_repeat_submissions();

-- Defined before the views below, which both call them.
--
-- How long a request may sit unacknowledged before someone has lost track of it.
-- Provisional numbers, to be reset from real deployments — but a stated wrong
-- number is auditable and an unstated one is not.
CREATE OR REPLACE FUNCTION triage_ack_deadline(sev TEXT)
RETURNS interval LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE sev
        WHEN 'Critical' THEN interval '15 minutes'
        WHEN 'Urgent'   THEN interval '1 hour'
        ELSE                 interval '4 hours'
    END;
$$;

-- Why a row is in the review pile, bucketed. The pile is not homogeneous and the
-- buckets need different human responses — some are a problem with the request,
-- others mean the node itself is broken.
CREATE OR REPLACE FUNCTION triage_review_reason(err TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN err IS NULL                              THEN NULL
        WHEN err ILIKE '%instruction injection%'      THEN 'Suspected injection'
        WHEN err ILIKE '%severity floor applied%'     THEN 'Floor overrode triage'
        WHEN err ILIKE '%no triageable detail%'       THEN 'No detail given'
        WHEN err ILIKE '%with no basis in%'           THEN 'Fabricated summary'
        WHEN err ILIKE '%incomplete submission%'      THEN 'Incomplete submission'
        WHEN err ILIKE '%unrecognised%'               THEN 'Unrecognised value'
        WHEN err ILIKE '%getaddrinfo%'
          OR err ILIKE '%ECONN%'
          OR err ILIKE '%timeout%'
          OR err ILIKE '%no message content%'
          OR err ILIKE '%Ollama%'                     THEN 'Model unavailable'
        ELSE                                               'Other'
    END;
$$;

-- What a coordinator should have open on screen. Sorted by real-world urgency,
-- which is not alphabetical order on the severity column.
CREATE OR REPLACE VIEW active_queue AS
SELECT
    id,
    received_at,
    severity,
    category,
    needs_review,
    status,
    assigned_to,
    reporter_name,
    location_text,
    people_affected,
    summary,
    raw_message,
    -- Appended, not inserted: CREATE OR REPLACE VIEW cannot reorder columns.
    duplicate_of,
    (SELECT count(*) FROM requests other
      WHERE other.dedupe_key = requests.dedupe_key
        AND other.dedupe_key IS NOT NULL
        AND other.id <> requests.id) AS other_submissions,
    round(extract(epoch FROM (now() - received_at)) / 60)::int AS minutes_open,
    -- TRUE means this has waited longer than its severity allows and nobody has
    -- acknowledged it. Not an alarm by itself; something has to be watching.
    (status = 'New' AND now() - received_at > triage_ack_deadline(severity)) AS past_deadline
FROM requests
WHERE status IN ('New', 'Acknowledged', 'Dispatched')
ORDER BY
    CASE severity WHEN 'Critical' THEN 0 WHEN 'Urgent' THEN 1 ELSE 2 END,
    needs_review DESC,
    received_at;

-- Coordinator instrumentation -----------------------------------------------
--
-- The pipeline escalates and flags diligently. None of that is worth anything
-- unless a human reads the result, and "someone should watch the queue" is not a
-- procedure. These views exist so each check in OPERATIONS.md is one glance, and
-- so "nobody looked" becomes visible instead of silent.

-- The review pile, triageable. Ordered so the reasons a human must read
-- personally come before the ones that are only a missing classification.
CREATE OR REPLACE VIEW review_pile AS
SELECT
    r.id,
    r.received_at,
    round(extract(epoch FROM (now() - r.received_at)) / 60)::int AS minutes_open,
    triage_review_reason(r.triage_error) AS reason,
    r.severity,
    r.category,
    r.status,
    r.assigned_to,
    r.reporter_name,
    r.location_text,
    -- Deliberately last and deliberately present: for several of these reasons
    -- the summary is exactly what must not be trusted.
    r.summary,
    r.raw_message,
    r.triage_error
FROM requests r
WHERE r.needs_review
  AND r.status IN ('New', 'Acknowledged', 'Dispatched')
ORDER BY
    CASE triage_review_reason(r.triage_error)
        WHEN 'Suspected injection'   THEN 0
        WHEN 'Fabricated summary'    THEN 1
        WHEN 'No detail given'       THEN 2
        WHEN 'Floor overrode triage' THEN 3
        WHEN 'Incomplete submission' THEN 4
        WHEN 'Unrecognised value'    THEN 5
        WHEN 'Model unavailable'     THEN 6
        ELSE 7
    END,
    r.received_at;

-- One row. What a shift lead looks at to answer "is this node keeping up, and is
-- anyone actually working the queue".
CREATE OR REPLACE VIEW queue_health AS
SELECT
    count(*) FILTER (WHERE status = 'New')                                    AS unacknowledged,
    count(*) FILTER (WHERE status = 'New' AND severity = 'Critical')          AS unacknowledged_critical,
    count(*) FILTER (WHERE status = 'New'
                       AND now() - received_at > triage_ack_deadline(severity)) AS past_deadline,
    count(*) FILTER (WHERE status = 'New' AND severity = 'Critical'
                       AND now() - received_at > triage_ack_deadline('Critical')) AS critical_past_deadline,
    count(*) FILTER (WHERE needs_review AND status <> 'Resolved')             AS needs_review_open,
    count(*) FILTER (WHERE status = 'Dispatched')                             AS dispatched_open,
    count(*) FILTER (WHERE status IN ('New','Acknowledged','Dispatched'))     AS total_open,
    -- If this is climbing, the node is broken and the answer is to fix Ollama,
    -- not to hand-triage a hundred rows.
    count(*) FILTER (WHERE triage_review_reason(triage_error) = 'Model unavailable'
                       AND received_at > now() - interval '1 hour')           AS model_failures_last_hour,
    count(*) FILTER (WHERE triage_review_reason(triage_error) = 'Suspected injection'
                       AND received_at > now() - interval '1 hour')           AS injections_last_hour,
    max(round(extract(epoch FROM (now() - received_at)) / 60)::int)
        FILTER (WHERE status = 'New')                                         AS oldest_unacknowledged_min,
    count(*) FILTER (WHERE received_at > now() - interval '1 hour')           AS arrived_last_hour
FROM requests;

-- Status changes, so "did anyone look at this" has an answer after the fact.
--
-- Note what this can and cannot tell you: db_user is the database role, which is
-- the same for every coordinator working through NocoDB. It identifies the
-- system, not the person. Attribution to a human depends on coordinators setting
-- assigned_to, which is a discipline, not a guarantee.
CREATE TABLE IF NOT EXISTS request_events (
    id          BIGSERIAL PRIMARY KEY,
    request_id  BIGINT NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
    at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    field       TEXT NOT NULL,
    old_value   TEXT,
    new_value   TEXT,
    assigned_to TEXT,
    db_user     TEXT NOT NULL DEFAULT current_user
);

CREATE INDEX IF NOT EXISTS request_events_request_idx ON request_events (request_id, at);
CREATE INDEX IF NOT EXISTS request_events_at_idx      ON request_events (at DESC);

CREATE OR REPLACE FUNCTION record_request_event() RETURNS trigger
LANGUAGE plpgsql
-- SECURITY DEFINER so the audit write happens as this function owner rather
-- than as whoever edited the row. Without it every role able to update a
-- request also needs INSERT on request_events, which leaves the audit trail
-- forgeable by exactly the people it exists to record. search_path is pinned
-- because a SECURITY DEFINER function must never resolve names through the
-- caller's path.
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO request_events (request_id, field, old_value, new_value, assigned_to)
        VALUES (NEW.id, 'status', OLD.status, NEW.status, NEW.assigned_to);
    END IF;
    IF NEW.assigned_to IS DISTINCT FROM OLD.assigned_to THEN
        INSERT INTO request_events (request_id, field, old_value, new_value, assigned_to)
        VALUES (NEW.id, 'assigned_to', OLD.assigned_to, NEW.assigned_to, NEW.assigned_to);
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS requests_record_events ON requests;
CREATE TRIGGER requests_record_events
    AFTER UPDATE ON requests
    FOR EACH ROW EXECUTE FUNCTION record_request_event();

COMMENT ON TABLE  requests            IS 'Every SOS submission from the captive portal, raw intake plus AI triage.';
COMMENT ON COLUMN requests.needs_review IS 'TRUE when triage failed or returned an unusable value; severity defaulted upward.';
COMMENT ON COLUMN requests.dedupe_key IS 'Normalised reporter name, set on insert. Groups repeat submissions. Location is deliberately excluded: it is the field people re-describe.';
COMMENT ON COLUMN requests.duplicate_of IS 'Head of this submission cluster. A link for context, NOT a reason to ignore the row.';
COMMENT ON VIEW   active_queue        IS 'Open requests ordered by urgency for triage coordinators.';
