-- A database role the agent cannot do damage with.
--
-- The MCP toolbelt runs queries on a local LLM's behalf. The threat is not a
-- hostile operator — anyone who can reach this database already has the node. It
-- is the model generating something destructive, or a runaway query monopolising
-- a machine that is also trying to triage incoming requests.
--
-- So the constraint is a grant, not a promise in application code. Every guard in
-- mcp/server.mjs could be bypassed and this role still cannot write.

\connect triage

-- Password comes from the environment rather than being written here, so it is
-- never committed. install.sh generates it into .env and docker-compose passes
-- it to the postgres container. \getenv needs Postgres 16+; the stack pins 17.
\getenv ro_password TRIAGE_RO_PASSWORD

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'triage_ro') THEN
        CREATE ROLE triage_ro LOGIN;
    END IF;
END $$;

-- Re-applied on every install, so rotating the value in .env is enough.
ALTER ROLE triage_ro PASSWORD :'ro_password';

REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM triage_ro;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM triage_ro;
REVOKE ALL ON SCHEMA public FROM triage_ro;

GRANT CONNECT ON DATABASE triage TO triage_ro;
GRANT USAGE ON SCHEMA public TO triage_ro;

-- SELECT only, and only on what a coordinator's question could need.
-- request_events is deliberately excluded: who acknowledged what is a staffing
-- record, and nothing the agent answers needs it.
GRANT SELECT ON requests, active_queue, review_pile, queue_health TO triage_ro;

-- A new table has to be considered rather than inherited.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM triage_ro;

-- A small node runs triage and this at the same time, and inference is already
-- serialised. A query that will not finish in five seconds is not worth slowing
-- the queue for.
ALTER ROLE triage_ro SET statement_timeout = '5s';
ALTER ROLE triage_ro SET idle_in_transaction_session_timeout = '10s';
-- Read-only at session level too, so even a SELECT calling a volatile function
-- cannot write.
ALTER ROLE triage_ro SET default_transaction_read_only = on;

COMMENT ON ROLE triage_ro IS
    'Read-only role for the MCP toolbelt. Cannot write, by grant rather than by convention.';
