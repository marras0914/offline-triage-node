-- The role the coordinator dashboard connects as.
--
-- NocoDB was documented to connect as triage_admin, which owns all three
-- databases. A coordinator could therefore add n8n_primary as a second data
-- source and read n8n's credential table. The blobs are encrypted, so nothing
-- leaked, but the coordinator UI having any reach into n8n is a boundary this
-- project said it wanted and did not have. Measured before this file existed:
-- triage_admin could SELECT all 126 tables in n8n_primary; triage_ro, correctly,
-- could read 0.
--
-- Scoped by grant rather than by NocoDB configuration, because configuration is
-- one careless click away from being different.

\connect triage

-- Password comes from the environment rather than being written here, same as
-- triage_ro. install.sh generates it into .env and compose passes it through.
\getenv coord_password TRIAGE_COORD_PASSWORD

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'triage_coord') THEN
        CREATE ROLE triage_coord LOGIN;
    END IF;
END $$;

-- Re-applied on every install, so rotating the value in .env is enough.
ALTER ROLE triage_coord PASSWORD :'coord_password';

REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM triage_coord;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM triage_coord;
REVOKE ALL ON SCHEMA public FROM triage_coord;

GRANT CONNECT ON DATABASE triage TO triage_coord;
GRANT USAGE ON SCHEMA public TO triage_coord;

-- Read the queue and the views a coordinator actually works from.
GRANT SELECT ON requests, active_queue, review_pile, queue_health TO triage_coord;

-- Write exactly the three fields a coordinator owns. Not severity, not the
-- person's own words, not the triage result: those record what came in and what
-- the model made of it, and a dashboard must not be able to rewrite history.
GRANT UPDATE (status, assigned_to, coordinator_notes) ON requests TO triage_coord;

-- Deliberately absent:
--   * INSERT and DELETE on requests. Requests arrive through the portal only,
--     and a request is closed, never removed.
--   * Any grant at all on request_events. The audit trail is written by the
--     record_request_event trigger, which is SECURITY DEFINER precisely so that
--     editing a row does not require the ability to write its own audit record.

-- A new table has to be considered rather than inherited.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM triage_coord;

-- More generous than triage_ro's five seconds, because a coordinator sorting a
-- large queue is a legitimate slow read, and unlike the agent there is a human
-- waiting who can see it is slow.
ALTER ROLE triage_coord SET statement_timeout = '10s';
ALTER ROLE triage_coord SET idle_in_transaction_session_timeout = '60s';

COMMENT ON ROLE triage_coord IS
    'Role for the NocoDB coordinator dashboard. Reads the queue; writes only status, assigned_to and coordinator_notes.';

-- Defence in depth. Postgres grants CONNECT to PUBLIC by default, so every role
-- can open a session on every database unless told otherwise. Both service
-- databases are owned by triage_admin, which keeps access implicitly, and the
-- services connect as that owner.
\connect postgres
REVOKE CONNECT ON DATABASE n8n_primary FROM PUBLIC;
REVOKE CONNECT ON DATABASE nocodb_meta FROM PUBLIC;
