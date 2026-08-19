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
    raw_message
FROM requests
WHERE status IN ('New', 'Acknowledged', 'Dispatched')
ORDER BY
    CASE severity WHEN 'Critical' THEN 0 WHEN 'Urgent' THEN 1 ELSE 2 END,
    needs_review DESC,
    received_at;

COMMENT ON TABLE  requests            IS 'Every SOS submission from the captive portal, raw intake plus AI triage.';
COMMENT ON COLUMN requests.needs_review IS 'TRUE when triage failed or returned an unusable value; severity defaulted upward.';
COMMENT ON VIEW   active_queue        IS 'Open requests ordered by urgency for triage coordinators.';
