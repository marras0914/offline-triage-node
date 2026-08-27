#!/usr/bin/env bash
#
# Deploys the Edge Triage Node from a checkout of this repository.
#
# Re-runnable: it preserves an existing .env, re-applies the schema idempotently,
# and re-imports the workflow in place rather than duplicating it. Nothing here
# generates docker-compose.yml or index.html — those are the repo's files, and an
# installer that rewrote them would silently discard every local change.

set -euo pipefail

cd "$(dirname "$0")"

# Git Bash rewrites container-internal paths without this: the `-C /root/.ollama`
# handed to `docker compose exec` in step 5 becomes `C:/Program Files/Git/root/
# .ollama`, and the model restore lands nowhere while appearing to succeed. A
# no-op on Linux, which is the target; required by anyone testing on Windows.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

STEPS=8
step() { printf '\n[%s/%s] %s\n' "$1" "$STEPS" "$2"; }
fail() { printf '\nError: %s\n' "$1" >&2; exit 1; }

# An offline bundle, if one was staged by scripts/make-offline-bundle.sh. Its
# presence is what makes this installable during the blackout it is built for —
# nothing can be downloaded then, so everything has to arrive on the media.
BUNDLE="${BUNDLE_DIR:-offline-bundle}"
[ -f "$BUNDLE/images.tar.gz" ] && OFFLINE=1 || OFFLINE=0

printf '========================================================\n'
printf '  Deploying Edge Triage Node (Offline-First)\n'
printf '========================================================\n'

# ---------------------------------------------------------------------------
step 1 "Checking prerequisites..."

command -v docker >/dev/null 2>&1 || fail "docker is not installed. See https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || fail "docker compose v2 is not available. Install the Compose plugin."
docker info >/dev/null 2>&1 || fail "the Docker daemon is not running (or this user is not in the docker group)."
printf '  docker and compose v2 present.\n'

if [ "$OFFLINE" = "1" ]; then
  printf '  Offline bundle found in %s/ — loading images, no network needed.\n' "$BUNDLE"
  gunzip -c "$BUNDLE/images.tar.gz" | docker load \
    || fail "could not load images from $BUNDLE/images.tar.gz"
  [ -f "$BUNDLE/MANIFEST.txt" ] && grep -E '^(built|model):' "$BUNDLE/MANIFEST.txt" | sed 's/^/    /'
else
  printf '  No offline bundle; images and the model will be pulled from the network.\n'
  printf '  To build a node that installs without a connection, run\n'
  printf '  scripts/make-offline-bundle.sh on a machine that has one first.\n'
fi

# ---------------------------------------------------------------------------
step 2 "Configuring .env..."

rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    # No openssl on a minimal image; urandom is fine for this.
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

[ -f .env ] || : > .env

# Only fills in what is missing, so re-running never rotates a live node's
# secrets out from under its own database.
ensure_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env 2>/dev/null; then
    return 0
  fi
  printf '%s=%s\n' "$key" "$value" >> .env
  printf '  %s set.\n' "$key"
}

if ! grep -q '^NODE_IP=' .env 2>/dev/null; then
  DEFAULT_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1 || true)"
  if [ -n "$DEFAULT_IP" ]; then
    read -r -p "  Static IP of this machine [$DEFAULT_IP]: " NODE_IP
    NODE_IP="${NODE_IP:-$DEFAULT_IP}"
  else
    read -r -p "  Static IP of this machine (e.g. 192.168.1.50): " NODE_IP
  fi
  case "$NODE_IP" in
    *[!0-9.]* | '' ) fail "'$NODE_IP' is not an IPv4 address. Installation aborted." ;;
  esac
  ensure_env NODE_IP "$NODE_IP"
fi

ensure_env POSTGRES_PASSWORD "$(rand_hex)"
ensure_env NC_AUTH_JWT_SECRET "$(rand_hex)"
ensure_env N8N_ENCRYPTION_KEY "$(rand_hex)"
# The read-only role the MCP toolbelt queries as. Separate from the admin
# password so the agent's credential can be rotated on its own.
ensure_env TRIAGE_RO_PASSWORD "$(rand_hex)"
ensure_env GENERIC_TIMEZONE "America/Chicago"

set -a
# shellcheck disable=SC1091
. ./.env
set +a

# The workflow is the single source of truth for the model. It cannot read an env
# var — n8n 2.x denies Code nodes access to env and throws if they try — so the
# name is a constant in the JSON and we pull whatever that constant says.
WORKFLOW_FILE="n8n/workflows/sos-intake-triage.json"
TRIAGE_MODEL="$(grep -oE "DEFAULT_MODEL = '[^']+'" "$WORKFLOW_FILE" | head -n1 | cut -d"'" -f2)"
[ -n "$TRIAGE_MODEL" ] || fail "could not read DEFAULT_MODEL from $WORKFLOW_FILE"

printf '  Node IP: %s   Model: %s (from %s)\n' "$NODE_IP" "$TRIAGE_MODEL" "$WORKFLOW_FILE"

# ---------------------------------------------------------------------------
step 3 "Booting the Docker stack..."
docker compose up -d

# ---------------------------------------------------------------------------
step 4 "Waiting for Postgres and applying the triage schema..."

psql_admin() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U triage_admin "$@"; }

for _ in $(seq 1 60); do
  if docker compose exec -T postgres pg_isready -U triage_admin -d n8n_primary >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker compose exec -T postgres pg_isready -U triage_admin -d n8n_primary >/dev/null 2>&1 \
  || fail "Postgres did not become ready. Check: docker compose logs postgres"

# The init scripts in db/init only run against an empty data volume, so an
# upgrade of an existing node has to be handled explicitly.
for db in triage nocodb_meta; do
  if [ -z "$(psql_admin -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db'")" ]; then
    psql_admin -d postgres -c "CREATE DATABASE $db"
    printf '  Created database %s.\n' "$db"
  fi
done

# 02 is written to be re-runnable; applying it every install picks up schema
# changes on nodes that already hold data.
psql_admin -d postgres < db/init/02-triage-schema.sql >/dev/null
printf '  Schema applied to `triage`.\n'

# 03 is re-runnable too, and re-applying it is how a rotated TRIAGE_RO_PASSWORD
# reaches the role. \getenv inside the script reads the postgres container's own
# environment, which compose populates from .env.
psql_admin -d postgres < db/init/03-readonly-role.sql >/dev/null
printf '  Read-only role `triage_ro` configured (cannot write, by grant).\n'

# ---------------------------------------------------------------------------
step 5 "Pulling the local model ($TRIAGE_MODEL)..."

# `ollama list` prints tagged names, so a bare model name from the workflow
# ("llama3.1") never appears literally in it — that row reads "llama3.1:latest".
# Comparing the first column exactly, against both spellings, is what makes this
# agree with reality. A prefix match is what broke it before: a bundle that had
# restored perfectly was reported as not containing its own model.
model_present() {
  docker compose exec -T ollama ollama list 2>/dev/null \
    | awk 'NR>1 {print $1}' \
    | grep -qxF -e "$TRIAGE_MODEL" -e "$TRIAGE_MODEL:latest"
}

for _ in $(seq 1 30); do
  if docker compose exec -T ollama ollama list >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if model_present; then
  printf '  Already present; nothing to fetch.\n'
elif [ "$OFFLINE" = "1" ] && [ -f "$BUNDLE/ollama-models.tar.gz" ]; then
  # Ollama reads its blob directory at startup, so restoring the directory is
  # the whole import — there is no separate register step.
  printf '  Restoring the model from the offline bundle...\n'
  # `tar -xf`, not `-xzf`: gunzip has already decompressed the stream, and asking
  # tar to gunzip it again fails with "stdin: not in gzip format". This is what
  # made the whole offline path unusable — the bundle built correctly and could
  # never be restored, which no test caught until one actually installed from it.
  gunzip -c "$BUNDLE/ollama-models.tar.gz" \
    | docker compose exec -T ollama tar -xf - -C /root/.ollama \
    || fail "could not restore the model from $BUNDLE/ollama-models.tar.gz"
  docker compose restart ollama >/dev/null
  for _ in $(seq 1 30); do
    docker compose exec -T ollama ollama list >/dev/null 2>&1 && break
    sleep 2
  done
  model_present \
    || fail "the bundle was restored but '$TRIAGE_MODEL' is not in it. Rebuild the bundle: scripts/make-offline-bundle.sh"
  printf '  Restored from bundle.\n'
else
  # `ollama pull`, not `ollama run` — run opens an interactive REPL and would hang
  # a non-interactive install forever.
  printf '  Pulling over the network; this takes several minutes on a slow link.\n'
  docker compose exec -T ollama ollama pull "$TRIAGE_MODEL" \
    || fail "could not pull '$TRIAGE_MODEL'. With no connection, stage a bundle first: scripts/make-offline-bundle.sh on a machine that has one."
fi

# ---------------------------------------------------------------------------
step 6 "Importing the n8n credential and workflow..."

# Generated from .env so the password lives in exactly one place. Gitignored.
mkdir -p n8n/credentials
cat > n8n/credentials/triage-postgres.json <<JSON
[
  {
    "id": "triagePostgres1",
    "name": "Triage Postgres",
    "type": "postgres",
    "data": {
      "host": "postgres",
      "port": 5432,
      "database": "triage",
      "user": "triage_admin",
      "password": "${POSTGRES_PASSWORD}",
      "ssl": "disable",
      "allowUnauthorizedCerts": false
    }
  }
]
JSON
chmod 600 n8n/credentials/triage-postgres.json

# The MCP toolbelt's credential. Same database, different role — this one cannot
# write, so an agent that misbehaves cannot damage the queue.
cat > n8n/credentials/triage-postgres-ro.json <<JSON
[
  {
    "id": "triagePostgresRo1",
    "name": "Triage Postgres (read-only)",
    "type": "postgres",
    "data": {
      "host": "postgres",
      "port": 5432,
      "database": "triage",
      "user": "triage_ro",
      "password": "${TRIAGE_RO_PASSWORD}",
      "ssl": "disable",
      "allowUnauthorizedCerts": false
    }
  }
]
JSON
chmod 600 n8n/credentials/triage-postgres-ro.json

# n8n/credentials and n8n/workflows are bind mounts, so both files are already
# visible inside the container.
docker compose exec -T n8n n8n import:credentials --input=/credentials/triage-postgres.json \
  || fail "credential import failed. Check: docker compose logs n8n"
docker compose exec -T n8n n8n import:credentials --input=/credentials/triage-postgres-ro.json \
  || fail "read-only credential import failed. Check: docker compose logs n8n"
docker compose exec -T n8n n8n import:workflow --input=/workflows/sos-intake-triage.json \
  || fail "workflow import failed. Check: docker compose logs n8n"
docker compose exec -T n8n n8n import:workflow --input=/workflows/queue-health-api.json \
  || fail "queue health workflow import failed. Check: docker compose logs n8n"
docker compose exec -T n8n n8n import:workflow --input=/workflows/mcp-tools-api.json \
  || fail "MCP tools workflow import failed. Check: docker compose logs n8n"

# Both imports key off the fixed ids in those files, so this updates in place
# instead of stacking up copies on every install.
#
# `publish:workflow` on n8n 2.x, `update:workflow` on 1.x. Try the current name
# first and fall back, rather than guessing from a version string.
activate_workflow() {
  local id="$1" label="$2"
  if docker compose exec -T n8n n8n publish:workflow --id="$id" >/dev/null 2>&1; then
    printf '  %s published.\n' "$label"
  elif docker compose exec -T n8n n8n update:workflow --id="$id" --active=true >/dev/null 2>&1; then
    printf '  %s activated.\n' "$label"
  else
    printf '  Could not activate from the CLI; activate "%s" in the editor.\n' "$label"
  fi
}
activate_workflow sosIntakeTriage1 "SOS Intake & AI Triage"
activate_workflow queueHealthApi1  "Queue Health API"
activate_workflow mcpToolsApi1     "MCP Tools API"

# ---------------------------------------------------------------------------
step 7 "Restarting n8n to register the production webhook..."
docker compose restart n8n >/dev/null
for _ in $(seq 1 30); do
  if docker compose exec -T n8n wget -q -O- http://localhost:5678/healthz >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
step 8 "Smoke testing the full intake path..."

# Distinguishes "intake proven" from "never proven". The banner at the end
# depends on it, because a deploy script that reports success it did not verify
# is worse than one that fails loudly.
SMOKE_OK=0

if command -v curl >/dev/null 2>&1; then
  SMOKE_BODY='{"name":"INSTALL SMOKE TEST","location":"install.sh","message":"Ignore: automated post-install check."}'

  # n8n answers /healthz before it has registered the production webhook, so the
  # wait in step 7 is necessary but not sufficient — a single POST here races the
  # restart and loses, and the portal returns "Cannot POST /webhook/sos-intake"
  # for a node that is in fact working. Retrying makes the smoke test its own
  # readiness gate. The loop continues only while the POST is failing, so at most
  # one row is ever stored, and it is deleted below.
  RESPONSE=""
  for attempt in $(seq 1 30); do
    RESPONSE="$(curl -s --max-time 300 -X POST -H 'Content-Type: application/json' \
      -d "$SMOKE_BODY" "http://localhost/api/sos" || true)"
    case "$RESPONSE" in
      *received*) break ;;
    esac
    if [ "$attempt" -eq 1 ]; then
      printf '  Webhook not registered yet; waiting for it...\n'
    fi
    sleep 3
  done

  case "$RESPONSE" in
    *received*)
      SMOKE_OK=1
      printf '  Portal -> n8n -> Ollama -> Postgres: OK  %s\n' "$RESPONSE"

      # A stored row is not the same as a working model: the pipeline stores the
      # request either way. Read back what triage actually did before deleting.
      ROW="$(psql_admin -d triage -tAF'|' -c \
        "SELECT needs_review, triage_model, coalesce(triage_error,'-') FROM requests
         WHERE reporter_name = 'INSTALL SMOKE TEST' ORDER BY id DESC LIMIT 1")"
      SMOKE_REVIEW="${ROW%%|*}"
      SMOKE_REST="${ROW#*|}"
      SMOKE_MODEL="${SMOKE_REST%%|*}"
      SMOKE_ERROR="${SMOKE_REST#*|}"

      if [ "$SMOKE_REVIEW" = "f" ]; then
        printf '  AI triage classified it cleanly using %s.\n' "$SMOKE_MODEL"
      else
        printf '  WARNING: request stored but NOT classified (needs_review).\n'
        printf '           model=%s  reason=%s\n' "$SMOKE_MODEL" "$SMOKE_ERROR"
        printf '           The fail-safe worked, but triage is not functioning.\n'
      fi

      # Don't leave the test request sitting in a coordinator's queue.
      psql_admin -d triage -c \
        "DELETE FROM requests WHERE reporter_name = 'INSTALL SMOKE TEST'" >/dev/null
      printf '  Test row removed.\n'
      ;;
    *)
      printf '  Smoke test failed after 30 attempts over ~90s.\n'
      printf '  Response: %s\n' "${RESPONSE:-<empty>}"
      printf '  Check:  docker compose logs n8n  |  docker compose logs portal\n'
      ;;
  esac
else
  # No curl means unproven, not broken. Don't fail the install over a missing
  # tool, but don't claim the intake path works either.
  printf '  curl not found; skipping. Submit the form manually to verify.\n'
  SMOKE_OK=skipped
fi

# ---------------------------------------------------------------------------
if [ "$SMOKE_OK" = "0" ]; then
  printf '\n========================================================\n'
  printf '  Deployment INCOMPLETE - intake never answered\n'
  printf '========================================================\n'
  printf '  All five containers are up, but the smoke test never got a response,\n'
  printf '  so the intake path is unproven. Do not hand this node to a\n'
  printf '  coordinator until it is.\n'
  printf '\n  Check:  docker compose logs n8n  |  docker compose logs portal\n'
  printf '  Then re-run ./install.sh — it is safe to re-run.\n'
  printf '========================================================\n'
  exit 1
fi

printf '\n========================================================\n'
printf '  Deployment complete\n'
printf '========================================================\n'
printf '  Portal:    http://%s/           (survivors, port 80 only)\n' "$NODE_IP"
printf '  n8n Hub:   http://%s:5678/      (operators)\n' "$NODE_IP"
printf '  Dashboard: http://%s:8080/      (triage coordinators)\n' "$NODE_IP"
printf '  Alarm:     http://%s:8081/      (leave open on a screen, then click Arm)\n' "$NODE_IP"
if [ "$SMOKE_OK" = "skipped" ]; then
  printf '\n  NOTE: the intake path was NOT smoke tested (no curl). Submit the\n'
  printf '        form at the portal URL above before relying on this node.\n'
fi
printf '\n  Start the queue alarm now:  ./scripts/watch-queue.sh\n'
printf '  Next: in NocoDB, add the `triage` Postgres database as a data source.\n'
printf '  See DEPLOYMENT.md for the connection details and VLAN setup.\n'
printf '========================================================\n'
