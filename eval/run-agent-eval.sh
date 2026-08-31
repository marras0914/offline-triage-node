#!/usr/bin/env bash
#
# Runs the MCP agent against a throwaway queue and scores the answers.
#
#   ./eval/run-agent-eval.sh                       # the workflow's own model
#   ./eval/run-agent-eval.sh --model llama3.2:3b   # compare a smaller one
#
# Builds its own Postgres and n8n on a private network, loads agent-fixture.sql,
# and tears everything down afterwards. It never touches a running node — the
# fixture TRUNCATEs, so pointing this at live field data would destroy it.
#
# Ollama is reused rather than recreated. Set OLLAMA_CONTAINER to an existing one
# (default: the compose stack's), or OLLAMA_MODELS_VOLUME to start a throwaway
# from a volume that already holds the models.
set -uo pipefail
cd "$(dirname "$0")/.."

MODEL=""
JSON=""
QUESTIONS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="${2:-}"; shift 2 ;;
    --json)  JSON="${2:-}"; shift 2 ;;
    # A subset file, for chasing one failing case without paying for all ten.
    --questions) QUESTIONS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

[ -n "$MODEL" ] || MODEL="$(grep -oE "DEFAULT_MODEL = '[^']+'" n8n/workflows/sos-intake-triage.json | head -n1 | cut -d"'" -f2)"

NET="agenteval-net-$$"
PG="agenteval-pg-$$"
N8N="agenteval-n8n-$$"
OLLAMA_OWNED=""

# Generated per run rather than written here. Every container below is on a
# throwaway network, publishes no port, and is removed on exit, so these only have
# to hold for the life of the eval — but a literal in the file is one a secret
# scanner flags and a reader can mistake for a real credential. Same generator as
# install.sh. PG_PW must reach both Postgres and n8n, and RO_PW both Postgres and
# the credential JSON, so each is generated once and passed twice.
rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}
PG_PW="$(rand_hex)"
RO_PW="$(rand_hex)"
COORD_PW="$(rand_hex)"

PG_IMAGE="$(awk '/^  postgres:/ {f=1} f && /image:/ {print $2; exit}' docker-compose.yml)"
N8N_IMAGE="$(awk '/^  n8n:/ {f=1} f && /image:/ {print $2; exit}' docker-compose.yml)"
OLLAMA_IMAGE="$(awk '/^  ollama:/ {f=1} f && /image:/ {print $2; exit}' docker-compose.yml)"

CREDS_ERR="$(pwd -W 2>/dev/null || pwd)/.agent-eval-creds.err"

cleanup() {
  docker rm -f "$PG" "$N8N" >/dev/null 2>&1
  [ -n "$OLLAMA_OWNED" ] && docker rm -f "$OLLAMA_OWNED" >/dev/null 2>&1
  # Disconnect a borrowed Ollama rather than leaving it attached to a dead network.
  [ -z "$OLLAMA_OWNED" ] && [ -n "${OLLAMA_ALIAS:-}" ] \
    && docker network disconnect "$NET" "$OLLAMA_ALIAS" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -f "$CREDS_ERR"
}
trap cleanup EXIT

printf 'Agent eval — model %s\n\n' "$MODEL"

docker network create "$NET" >/dev/null 2>&1

# --- Ollama: reuse whatever already holds the models rather than re-pulling GBs.
OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-$(docker compose ps -q ollama 2>/dev/null | head -1)}"
if [ -n "$OLLAMA_CONTAINER" ] && docker inspect "$OLLAMA_CONTAINER" >/dev/null 2>&1; then
  docker network connect "$NET" "$OLLAMA_CONTAINER" >/dev/null 2>&1
  OLLAMA_ALIAS="$(docker inspect -f '{{.Name}}' "$OLLAMA_CONTAINER" | sed 's|^/||')"
elif [ -n "${OLLAMA_MODELS_VOLUME:-}" ]; then
  OLLAMA_OWNED="agenteval-ollama-$$"
  docker run -d --name "$OLLAMA_OWNED" --network "$NET" \
    -v "$OLLAMA_MODELS_VOLUME:/root/.ollama" "$OLLAMA_IMAGE" >/dev/null \
    || { echo "could not start Ollama"; exit 1; }
  OLLAMA_ALIAS="$OLLAMA_OWNED"
  for _ in $(seq 1 60); do docker exec "$OLLAMA_OWNED" ollama list >/dev/null 2>&1 && break; sleep 2; done
else
  echo "No Ollama found. Start the stack, or set OLLAMA_CONTAINER / OLLAMA_MODELS_VOLUME." >&2
  exit 1
fi
printf '  Ollama: %s\n' "$OLLAMA_ALIAS"

# --- throwaway Postgres, built from the real init scripts
[ -n "$PG_IMAGE" ] || { echo "could not read the postgres image from docker-compose.yml" >&2; exit 1; }
[ -n "$N8N_IMAGE" ] || { echo "could not read the n8n image from docker-compose.yml" >&2; exit 1; }

if ! docker run -d --name "$PG" --network "$NET" --network-alias postgres \
       -e POSTGRES_USER=triage_admin -e POSTGRES_PASSWORD="$PG_PW" -e POSTGRES_DB=n8n_primary \
       -e TRIAGE_RO_PASSWORD="$RO_PW" -e TRIAGE_COORD_PASSWORD="$COORD_PW" \
       -v "$(pwd -W 2>/dev/null || pwd)/db/init:/docker-entrypoint-initdb.d:ro" \
       "$PG_IMAGE" >/dev/null 2>"$CREDS_ERR"; then
  echo "could not start Postgres:" >&2; cat "$CREDS_ERR" >&2; exit 1
fi

# Two waits, not one. Postgres accepts connections on its socket partway through
# running the init scripts and then restarts, so a single pg_isready can pass
# against a server that is about to go away. Wait for readiness, then require it
# to still be ready a moment later.
pg_ready() { docker exec "$PG" pg_isready -U triage_admin -d triage >/dev/null 2>&1; }
for _ in $(seq 1 60); do pg_ready && break; sleep 2; done
sleep 3
for _ in $(seq 1 30); do pg_ready && break; sleep 2; done

if ! pg_ready; then
  # A bare "never ready" hides whether the container died, an init script failed,
  # or the mount was empty — which is the difference between three fixes.
  echo "Postgres never became ready." >&2
  echo "  container: $(docker ps -a --filter "name=$PG" --format '{{.Status}}')" >&2
  echo "  last log lines:" >&2
  docker logs --tail 20 "$PG" 2>&1 | sed 's/^/    /' >&2
  exit 1
fi

docker exec -i "$PG" psql -q -v ON_ERROR_STOP=1 -U triage_admin -d postgres < eval/agent-fixture.sql >/dev/null \
  || { echo "could not load the fixture"; exit 1; }
printf '  Fixture loaded: %s requests\n' \
  "$(docker exec "$PG" psql -U triage_admin -d triage -tAc 'SELECT count(*) FROM requests' | tr -d '[:space:]')"

# --- throwaway n8n with the read-only credential and the tools workflow
# Deliberately inside the project, not mktemp -d. On Windows a Git Bash temp path
# like /tmp/tmp.XXXX is not a path Docker Desktop can mount, so the mount silently
# resolves to nothing, the credential import fails, and the whole eval then scores
# a broken tool surface. That happened.
CREDS="$(pwd -W 2>/dev/null || pwd)/.agent-eval-creds"
rm -rf "$CREDS"; mkdir -p "$CREDS"
cat > "$CREDS/ro.json" <<JSON
[{"id":"triagePostgresRo1","name":"Triage Postgres (read-only)","type":"postgres","data":{"host":"postgres","port":5432,"database":"triage","user":"triage_ro","password":"$RO_PW","ssl":"disable","allowUnauthorizedCerts":false}}]
JSON

docker run -d --name "$N8N" --network "$NET" --network-alias n8n \
  -e N8N_ENCRYPTION_KEY="$(rand_hex)" \
  -e DB_TYPE=postgresdb -e DB_POSTGRESDB_HOST=postgres -e DB_POSTGRESDB_PORT=5432 \
  -e DB_POSTGRESDB_DATABASE=n8n_primary -e DB_POSTGRESDB_USER=triage_admin \
  -e DB_POSTGRESDB_PASSWORD="$PG_PW" \
  -e N8N_DIAGNOSTICS_ENABLED=false -e GENERIC_TIMEZONE=UTC -e N8N_SECURE_COOKIE=false \
  -v "$(pwd -W 2>/dev/null || pwd)/n8n/workflows:/workflows:ro" \
  -v "$CREDS:/credentials:ro" \
  -v "$(pwd -W 2>/dev/null || pwd)/mcp:/mcp:ro" \
  -v "$(pwd -W 2>/dev/null || pwd)/eval:/eval:ro" \
  "$N8N_IMAGE" >/dev/null || { echo "could not start n8n"; exit 1; }
for _ in $(seq 1 90); do docker exec "$N8N" wget -q -O- http://localhost:5678/healthz >/dev/null 2>&1 && break; sleep 2; done

# Not silenced. A failed credential import is exactly how this eval came to score
# a broken tool surface, so it aborts rather than continuing quietly.
docker exec "$N8N" n8n import:credentials --input=/credentials/ro.json 2>&1 | grep -qi 'success' \
  || { echo "credential import failed — the eval would score a broken tool surface" >&2; exit 1; }
docker exec "$N8N" n8n import:workflow --input=/workflows/mcp-tools-api.json 2>&1 | grep -qi 'success' \
  || { echo "workflow import failed" >&2; exit 1; }
docker exec "$N8N" n8n publish:workflow --id=mcpToolsApi1 >/dev/null 2>&1
docker restart "$N8N" >/dev/null
for _ in $(seq 1 90); do docker exec "$N8N" wget -q -O- http://localhost:5678/healthz >/dev/null 2>&1 && break; sleep 2; done
sleep 8

# Sanity check before scoring anything: an eval that silently measures a broken
# tool surface would report the model as useless.
# The probe asserts real data, not merely a well-shaped reply. An earlier version
# checked for the string "row_count", which is present even when the query never
# ran — so it reported a green tools API while every answer came from a passthrough
# item. Assert a field only a real request row has, and no error.
PROBE="$(docker exec "$N8N" sh -c 'wget -q -O- --post-data="{\"tool\":\"search_requests\",\"args\":{\"text\":\"insulin\"}}" --header="Content-Type: application/json" http://localhost:5678/webhook/mcp-tool' 2>/dev/null)"
case "$PROBE" in
  *'"error":null'*'reporter_name'*|*reporter_name*'"error":null'*)
    printf '  Tools API returning real rows\n\n' ;;
  *)
    echo "the tools API is not returning request rows; aborting rather than scoring nonsense" >&2
    echo "$PROBE" | head -c 400 >&2; echo >&2
    exit 1 ;;
esac

# The agent runs in the container, where node and the internal network are. The
# harness runs on the host, because it has to shell back in per question — and
# there is no docker CLI inside the container to do that from.
EXEC="docker exec -e TRIAGE_AGENT_MODEL=$MODEL -e TRIAGE_AGENT_TRACE=1 -e OLLAMA_URL=http://$OLLAMA_ALIAS:11434 $N8N node /mcp/agent.mjs"

command -v node >/dev/null 2>&1 \
  || { echo "the harness needs node on the host (the agent itself does not)." >&2; exit 1; }

set -- --label "$MODEL" --exec "$EXEC"
[ -n "$JSON" ] && set -- "$@" --json "$JSON"
[ -n "$QUESTIONS" ] && set -- "$@" --questions "$QUESTIONS"

node eval/run-agent-eval.mjs "$@"
