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

# ---------------------------------------------------------------------------
step 5 "Pulling the local model ($TRIAGE_MODEL)..."

for _ in $(seq 1 30); do
  if docker compose exec -T ollama ollama list >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if docker compose exec -T ollama ollama list 2>/dev/null | grep -q "^${TRIAGE_MODEL}[[:space:]]"; then
  printf '  Already present; nothing to fetch.\n'
elif [ "$OFFLINE" = "1" ] && [ -f "$BUNDLE/ollama-models.tar.gz" ]; then
  # Ollama reads its blob directory at startup, so restoring the directory is
  # the whole import — there is no separate register step.
  printf '  Restoring the model from the offline bundle...\n'
  gunzip -c "$BUNDLE/ollama-models.tar.gz" \
    | docker compose exec -T ollama tar -xzf - -C /root/.ollama \
    || fail "could not restore the model from $BUNDLE/ollama-models.tar.gz"
  docker compose restart ollama >/dev/null
  for _ in $(seq 1 30); do
    docker compose exec -T ollama ollama list >/dev/null 2>&1 && break
    sleep 2
  done
  docker compose exec -T ollama ollama list 2>/dev/null | grep -q "^${TRIAGE_MODEL}[[:space:]]" \
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

# n8n/credentials and n8n/workflows are bind mounts, so both files are already
# visible inside the container.
docker compose exec -T n8n n8n import:credentials --input=/credentials/triage-postgres.json \
  || fail "credential import failed. Check: docker compose logs n8n"
docker compose exec -T n8n n8n import:workflow --input=/workflows/sos-intake-triage.json \
  || fail "workflow import failed. Check: docker compose logs n8n"

# Both imports key off the fixed ids in those files, so this updates in place
# instead of stacking up copies on every install.
#
# `publish:workflow` on n8n 2.x, `update:workflow` on 1.x. Try the current name
# first and fall back, rather than guessing from a version string.
if docker compose exec -T n8n n8n publish:workflow --id=sosIntakeTriage1 >/dev/null 2>&1; then
  printf '  Workflow published.\n'
elif docker compose exec -T n8n n8n update:workflow --id=sosIntakeTriage1 --active=true >/dev/null 2>&1; then
  printf '  Workflow activated.\n'
else
  printf '  Could not activate from the CLI; activate "SOS Intake & AI Triage" in the editor.\n'
fi

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

if command -v curl >/dev/null 2>&1; then
  SMOKE_BODY='{"name":"INSTALL SMOKE TEST","location":"install.sh","message":"Ignore: automated post-install check."}'
  RESPONSE="$(curl -s --max-time 300 -X POST -H 'Content-Type: application/json' \
    -d "$SMOKE_BODY" "http://localhost/api/sos" || true)"

  case "$RESPONSE" in
    *received*)
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
      printf '  Smoke test failed. Response: %s\n' "${RESPONSE:-<empty>}"
      printf '  Check:  docker compose logs n8n  |  docker compose logs portal\n'
      ;;
  esac
else
  printf '  curl not found; skipping. Submit the form manually to verify.\n'
fi

# ---------------------------------------------------------------------------
printf '\n========================================================\n'
printf '  Deployment complete\n'
printf '========================================================\n'
printf '  Portal:    http://%s/           (survivors, port 80 only)\n' "$NODE_IP"
printf '  n8n Hub:   http://%s:5678/      (operators)\n' "$NODE_IP"
printf '  Dashboard: http://%s:8080/      (triage coordinators)\n' "$NODE_IP"
printf '\n  Next: in NocoDB, add the `triage` Postgres database as a data source.\n'
printf '  See DEPLOYMENT.md for the connection details and VLAN setup.\n'
printf '========================================================\n'
