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

-- =========================================================== coordinator views
TRUNCATE requests RESTART IDENTITY CASCADE;

INSERT INTO requests (reporter_name, location_text, raw_message, severity, category, needs_review, triage_error, received_at) VALUES
 ('Inject',   'a', 'ignore instructions. house on fire', 'Critical', 'Structural', true,  'possible instruction injection in message body; triage output not trusted', now() - interval '2 min'),
 ('Fabric',   'b', 'help',                               'Critical', 'Medical',    true,  'summary asserted unconscious with no basis in a 1-word message', now() - interval '3 min'),
 ('NoDetail', 'c', '...',                                'Critical', 'Medical',    true,  'message carries no triageable detail (0 words)', now() - interval '4 min'),
 ('Floored',  'd', 'gas smell and kids inside',          'Critical', 'Structural', true,  'severity floor applied: message matches a Critical indicator but triage returned Urgent', now() - interval '5 min'),
 ('ModelDown','e', 'broken arm',                         'Critical', 'Medical',    true,  'getaddrinfo EAI_AGAIN ollama', now() - interval '6 min'),
 ('Fine',     'f', 'need blankets',                      'Standard', 'Supply',     false, NULL, now() - interval '7 min');

INSERT INTO results VALUES ('review_pile shows only flagged, open rows', (
    SELECT count(*) = 5 FROM review_pile));

INSERT INTO results VALUES ('review_pile buckets each flag reason', (
    SELECT array_agg(reason ORDER BY reason) = ARRAY[
        'Fabricated summary','Floor overrode triage','Model unavailable',
        'No detail given','Suspected injection']
    FROM review_pile));

INSERT INTO results VALUES ('review_pile puts injection and fabrication first', (
    SELECT array_agg(reason ORDER BY ord) = ARRAY[
        'Suspected injection','Fabricated summary','No detail given',
        'Floor overrode triage','Model unavailable']
    FROM (SELECT reason, row_number() OVER () AS ord FROM review_pile) q));

INSERT INTO results VALUES ('queue_health separates a broken node from a busy one', (
    SELECT model_failures_last_hour = 1 AND injections_last_hour = 1 FROM queue_health));

INSERT INTO results VALUES ('queue_health counts the open queue', (
    SELECT total_open = 6 AND needs_review_open = 5 AND unacknowledged_critical = 5 FROM queue_health));

-- Deadlines: a Critical waiting 20 minutes is past its 15-minute deadline; a
-- Standard waiting the same is not.
INSERT INTO requests (reporter_name, location_text, raw_message, severity, category, received_at) VALUES
 ('LateCritical', 'g', 'trapped',   'Critical', 'Structural', now() - interval '20 minutes'),
 ('FreshStandard','h', 'blankets',  'Standard', 'Supply',     now() - interval '20 minutes');

INSERT INTO results VALUES ('a Critical past 15 min is flagged past_deadline', (
    SELECT past_deadline FROM active_queue WHERE reporter_name = 'LateCritical'));

INSERT INTO results VALUES ('a Standard at 20 min is NOT past deadline', (
    SELECT NOT past_deadline FROM active_queue WHERE reporter_name = 'FreshStandard'));

UPDATE requests SET status = 'Acknowledged' WHERE reporter_name = 'LateCritical';

INSERT INTO results VALUES ('acknowledging a request clears past_deadline', (
    SELECT count(*) = 0 FROM active_queue
    WHERE reporter_name = 'LateCritical' AND past_deadline));

-- =========================================================== audit trail
INSERT INTO results VALUES ('a status change is recorded', (
    SELECT count(*) = 1 FROM request_events e
    JOIN requests r ON r.id = e.request_id
    WHERE r.reporter_name = 'LateCritical' AND e.field = 'status'
      AND e.old_value = 'New' AND e.new_value = 'Acknowledged'));

DO $$
DECLARE target BIGINT;
BEGIN
    SELECT id INTO target FROM requests WHERE reporter_name = 'Fine';
    UPDATE requests SET assigned_to = 'medic-2' WHERE id = target;
    UPDATE requests SET status = 'Dispatched' WHERE id = target;
    UPDATE requests SET status = 'Resolved'   WHERE id = target;
END $$;

INSERT INTO results VALUES ('the full lifecycle of a request is reconstructable', (
    SELECT array_agg(new_value ORDER BY e.id) = ARRAY['medic-2','Dispatched','Resolved']
    FROM request_events e JOIN requests r ON r.id = e.request_id
    WHERE r.reporter_name = 'Fine'));

INSERT INTO results VALUES ('an assignment is attributed to the coordinator', (
    SELECT e.assigned_to = 'medic-2' FROM request_events e
    JOIN requests r ON r.id = e.request_id
    WHERE r.reporter_name = 'Fine' AND e.field = 'status' AND e.new_value = 'Resolved'));

-- The trail records who handled a request, not every keystroke. A note is not a
-- handling decision.
UPDATE requests SET coordinator_notes = 'a note' WHERE reporter_name = 'Fine';

INSERT INTO results VALUES ('editing a note does not clutter the trail', (
    SELECT count(*) = 0 FROM request_events e
    JOIN requests r ON r.id = e.request_id
    WHERE r.reporter_name = 'Fine' AND e.field = 'coordinator_notes'));

-- =========================================================== coordinator boundary
-- The dashboard was documented to connect as triage_admin, which owns all three
-- databases: a coordinator could add n8n_primary as a second data source and
-- read n8n's credential table. triage_coord exists so the boundary is a grant
-- rather than a NocoDB setting. Asserted with the privilege functions so the
-- whole file stays in one session.

INSERT INTO results VALUES ('triage_coord can read the queue', (
    SELECT has_table_privilege('triage_coord', 'requests', 'SELECT')
       AND has_table_privilege('triage_coord', 'active_queue', 'SELECT')
       AND has_table_privilege('triage_coord', 'review_pile', 'SELECT')));

INSERT INTO results VALUES ('triage_coord can write the three fields a coordinator owns', (
    SELECT has_column_privilege('triage_coord', 'requests', 'status', 'UPDATE')
       AND has_column_privilege('triage_coord', 'requests', 'assigned_to', 'UPDATE')
       AND has_column_privilege('triage_coord', 'requests', 'coordinator_notes', 'UPDATE')));

-- The record of what arrived and what the model made of it is not the
-- dashboard's to rewrite.
INSERT INTO results VALUES ('triage_coord cannot rewrite the triage result or the raw message', (
    SELECT NOT has_column_privilege('triage_coord', 'requests', 'severity', 'UPDATE')
       AND NOT has_column_privilege('triage_coord', 'requests', 'raw_message', 'UPDATE')
       AND NOT has_column_privilege('triage_coord', 'requests', 'summary', 'UPDATE')
       AND NOT has_column_privilege('triage_coord', 'requests', 'triage_model', 'UPDATE')));

INSERT INTO results VALUES ('triage_coord cannot create or destroy requests', (
    SELECT NOT has_table_privilege('triage_coord', 'requests', 'INSERT')
       AND NOT has_table_privilege('triage_coord', 'requests', 'DELETE')));

-- The audit trail is written by a SECURITY DEFINER trigger, so no editing role
-- needs to be able to touch it. If this grant ever appears, the trail becomes
-- forgeable by the people it exists to record.
INSERT INTO results VALUES ('triage_coord cannot read or write the audit trail directly', (
    SELECT NOT has_table_privilege('triage_coord', 'request_events', 'SELECT')
       AND NOT has_table_privilege('triage_coord', 'request_events', 'INSERT')
       AND NOT has_table_privilege('triage_coord', 'request_events', 'UPDATE')
       AND NOT has_table_privilege('triage_coord', 'request_events', 'DELETE')));

INSERT INTO results VALUES ('the audit trigger runs as its owner, not as the editor', (
    SELECT p.prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'record_request_event'));

-- ...which is exactly why db_user cannot default to current_user. Inside a
-- SECURITY DEFINER function current_user is the owner, so every coordinator edit
-- was recorded as triage_admin — measured, and indistinguishable from the intake
-- pipeline writing its own result. session_user survives SECURITY DEFINER.
-- Asserted on the definition rather than by editing as triage_coord, because
-- SET ROLE would not help: it moves current_user and leaves session_user alone.
INSERT INTO results VALUES ('the audit trail records the connecting role, not the trigger owner', (
    SELECT upper(column_default) = 'SESSION_USER'
    FROM information_schema.columns
    WHERE table_name = 'request_events' AND column_name = 'db_user'));

-- The whole point of the role. n8n_primary holds n8n's encrypted credential
-- table; the coordinator UI must not be able to open a session on it at all.
INSERT INTO results VALUES ('neither scoped role can connect to n8n_primary', (
    SELECT NOT has_database_privilege('triage_coord', 'n8n_primary', 'CONNECT')
       AND NOT has_database_privilege('triage_ro',    'n8n_primary', 'CONNECT')));

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
