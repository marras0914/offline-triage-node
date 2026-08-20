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
        AND other.id <> requests.id) AS other_submissions
FROM requests
WHERE status IN ('New', 'Acknowledged', 'Dispatched')
ORDER BY
    CASE severity WHEN 'Critical' THEN 0 WHEN 'Urgent' THEN 1 ELSE 2 END,
    needs_review DESC,
    received_at;

COMMENT ON TABLE  requests            IS 'Every SOS submission from the captive portal, raw intake plus AI triage.';
COMMENT ON COLUMN requests.needs_review IS 'TRUE when triage failed or returned an unusable value; severity defaulted upward.';
COMMENT ON COLUMN requests.dedupe_key IS 'Normalised reporter name, set on insert. Groups repeat submissions. Location is deliberately excluded: it is the field people re-describe.';
COMMENT ON COLUMN requests.duplicate_of IS 'Head of this submission cluster. A link for context, NOT a reason to ignore the row.';
COMMENT ON VIEW   active_queue        IS 'Open requests ordered by urgency for triage coordinators.';
