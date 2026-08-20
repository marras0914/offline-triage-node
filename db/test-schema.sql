-- Schema regression tests.
--
-- These assert behaviour, not structure. The properties here are the ones that
-- decide whether a request reaches a human, and several are counter-intuitive
-- enough that a reasonable person could "simplify" them away — so they are
-- pinned rather than described.
--
-- Run with db/test-schema.sh. Every assertion is collected; the script exits
-- non-zero if any failed.

\connect triage
\set ON_ERROR_STOP on
\pset pager off

CREATE TEMP TABLE results (label TEXT, ok BOOLEAN);
TRUNCATE requests RESTART IDENTITY CASCADE;

-- =========================================================== defaults
INSERT INTO requests (reporter_name, location_text, raw_message)
VALUES ('Unclassified', 'nowhere', 'the model was down');

INSERT INTO results VALUES ('an insert with no classification defaults to Critical/Medical/New', (
    SELECT severity = 'Critical' AND category = 'Medical' AND status = 'New'
    FROM requests WHERE reporter_name = 'Unclassified'));

-- =========================================================== constraints
DO $$
BEGIN
    BEGIN
        INSERT INTO requests (reporter_name, location_text, raw_message, severity)
        VALUES ('x', 'y', 'z', 'SUPER URGENT');
        INSERT INTO results VALUES ('an invalid severity is rejected', FALSE);
    EXCEPTION WHEN check_violation THEN
        INSERT INTO results VALUES ('an invalid severity is rejected', TRUE);
    END;
    BEGIN
        INSERT INTO requests (reporter_name, location_text, raw_message, people_affected)
        VALUES ('x', 'y', 'z', -5);
        INSERT INTO results VALUES ('a negative people_affected is rejected', FALSE);
    EXCEPTION WHEN check_violation THEN
        INSERT INTO results VALUES ('a negative people_affected is rejected', TRUE);
    END;
END $$;

-- =========================================================== queue ordering
TRUNCATE requests RESTART IDENTITY CASCADE;
INSERT INTO requests (reporter_name, location_text, raw_message, severity, category, received_at, needs_review) VALUES
 ('StandardOld',      'a', 'blankets',      'Standard', 'Supply',     now() - interval '3 hours', false),
 ('UrgentNew',        'b', 'broken leg',    'Urgent',   'Medical',    now() - interval '10 min',  false),
 ('CriticalNewest',   'c', 'trapped',       'Critical', 'Structural', now(),                     false),
 ('CriticalOld',      'd', 'not breathing', 'Critical', 'Medical',    now() - interval '2 hours', false),
 ('CriticalFlagged',  'e', 'garbled',       'Critical', 'Medical',    now() - interval '1 min',   true),
 ('ResolvedCritical', 'f', 'handled',       'Critical', 'Medical',    now() - interval '4 hours', false);
UPDATE requests SET status = 'Resolved' WHERE reporter_name = 'ResolvedCritical';

INSERT INTO results VALUES ('active_queue orders by urgency, flagged first, then oldest', (
    SELECT array_agg(reporter_name ORDER BY ord) = ARRAY['CriticalFlagged','CriticalOld','CriticalNewest','UrgentNew','StandardOld']
    FROM (SELECT reporter_name, row_number() OVER () AS ord FROM active_queue) q));

INSERT INTO results VALUES ('resolved requests leave the queue', (
    SELECT count(*) = 0 FROM active_queue WHERE reporter_name = 'ResolvedCritical'));

INSERT INTO results VALUES ('updated_at is bumped on update', (
    SELECT updated_at > received_at FROM requests WHERE reporter_name = 'ResolvedCritical'));

-- =========================================================== repeat submissions
--
-- The property that matters most in this file. A household's SECOND message is
-- usually an escalation, so linking must never remove it from the queue.
TRUNCATE requests RESTART IDENTITY CASCADE;
INSERT INTO requests (reporter_name, location_text, raw_message, severity, category) VALUES
 ('The Smith Family', '4th and Main', 'we need water and blankets',                    'Standard', 'Supply'),
 ('the smith family', '4th & Main',   'UPDATE grandma collapsed she is not breathing',  'Critical', 'Medical');

INSERT INTO results VALUES ('a repeat submission is linked to the cluster head', (
    SELECT duplicate_of = 1 FROM requests WHERE id = 2));

INSERT INTO results VALUES ('name normalisation survives case and & vs and', (
    SELECT count(DISTINCT dedupe_key) = 1 FROM requests WHERE id IN (1, 2)));

INSERT INTO results VALUES ('A WORSE FOLLOW-UP IS NEVER HIDDEN FROM THE QUEUE', (
    SELECT count(*) = 2 FROM active_queue WHERE id IN (1, 2)));

INSERT INTO results VALUES ('the escalation sorts above the original', (
    SELECT id = 2 FROM (SELECT id, row_number() OVER () AS ord FROM active_queue) q WHERE ord = 1));

INSERT INTO results VALUES ('a coordinator can see the cluster size', (
    SELECT other_submissions = 1 FROM active_queue WHERE id = 2));

-- Byte-identical text inside ten minutes carries no new information, and the
-- original is still queued, so removing this one loses nothing.
INSERT INTO requests (reporter_name, location_text, raw_message, severity, category) VALUES
 ('Jones', 'Elm St', 'no power and out of water', 'Standard', 'Supply'),
 ('Jones', 'Elm St', 'no power and out of water', 'Standard', 'Supply');

INSERT INTO results VALUES ('an identical repeat inside 10 min is marked Duplicate', (
    SELECT status = 'Duplicate' FROM requests WHERE reporter_name = 'Jones' ORDER BY id DESC LIMIT 1));

INSERT INTO results VALUES ('...and its original stays in the queue', (
    SELECT count(*) = 1 FROM active_queue WHERE reporter_name = 'Jones'));

-- A re-ask is not a duplicate: they are still waiting.
INSERT INTO requests (reporter_name, location_text, raw_message, severity, category, received_at) VALUES
 ('Petrov', 'Yard', 'still waiting for insulin', 'Urgent', 'Medical', now() - interval '20 minutes');
INSERT INTO requests (reporter_name, location_text, raw_message, severity, category) VALUES
 ('Petrov', 'Yard', 'still waiting for insulin', 'Urgent', 'Medical');

INSERT INTO results VALUES ('an identical re-ask after 10 min stays in the queue', (
    SELECT count(*) = 2 FROM active_queue WHERE reporter_name = 'Petrov'));

-- Cluster shape: a star, so a coordinator reads one group rather than walking a
-- chain of links.
INSERT INTO requests (reporter_name, location_text, raw_message, severity, category) VALUES
 ('Okafor', 'Depot', 'first',  'Standard', 'Supply'),
 ('Okafor', 'Depot', 'second', 'Standard', 'Supply'),
 ('Okafor', 'Depot', 'third',  'Urgent',   'Medical'),
 ('Okafor', 'Depot', 'fourth', 'Critical', 'Medical');

INSERT INTO results VALUES ('a run of submissions forms a star, not a chain', (
    SELECT count(DISTINCT duplicate_of) = 1 FROM requests
    WHERE reporter_name = 'Okafor' AND duplicate_of IS NOT NULL));

INSERT INTO results VALUES ('every submission in a cluster stays in the queue', (
    SELECT count(*) = 4 FROM active_queue WHERE reporter_name = 'Okafor'));

-- Things that must NOT be grouped.
INSERT INTO requests (reporter_name, location_text, raw_message, severity, category) VALUES
 ('Alvarez', 'Depot', 'need formula', 'Urgent', 'Supply'),
 ('Bianchi', 'Depot', 'need formula', 'Urgent', 'Supply');

INSERT INTO results VALUES ('different reporters are not grouped', (
    SELECT count(*) = 0 FROM requests
    WHERE reporter_name IN ('Alvarez','Bianchi') AND duplicate_of IS NOT NULL));

INSERT INTO requests (reporter_name, location_text, raw_message, severity, category) VALUES
 ('', 'somewhere', 'anonymous one', 'Critical', 'Medical'),
 ('', 'elsewhere', 'anonymous two', 'Critical', 'Medical');

INSERT INTO results VALUES ('anonymous submissions do not form one giant cluster', (
    SELECT count(*) = 0 FROM requests WHERE reporter_name = '' AND duplicate_of IS NOT NULL));

-- A new day is a new problem.
INSERT INTO requests (reporter_name, location_text, raw_message, severity, category, received_at) VALUES
 ('Nakamura', 'Pier', 'day one: need water', 'Standard', 'Supply', now() - interval '7 hours');
INSERT INTO requests (reporter_name, location_text, raw_message, severity, category) VALUES
 ('Nakamura', 'Pier', 'day two: roof leaking', 'Standard', 'Structural');

INSERT INTO results VALUES ('a submission outside the 6h window is not linked', (
    SELECT count(*) = 0 FROM requests WHERE reporter_name = 'Nakamura' AND duplicate_of IS NOT NULL));

-- =========================================================== report
\echo ''
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, label FROM results ORDER BY ok, label;
\echo ''

SELECT count(*) FILTER (WHERE ok) || ' passed, '
    || count(*) FILTER (WHERE NOT ok OR ok IS NULL) || ' failed' AS summary
FROM results;

-- Non-zero exit for the runner.
DO $$
DECLARE failed INT;
BEGIN
    SELECT count(*) INTO failed FROM results WHERE ok IS NOT TRUE;
    IF failed > 0 THEN
        RAISE EXCEPTION '% schema assertion(s) failed', failed;
    END IF;
END $$;
