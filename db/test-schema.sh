#!/usr/bin/env bash
#
# Runs the schema regression tests against a throwaway Postgres, built from the
# same init scripts a real node uses. Touches nothing on a live deployment.
#
#   ./db/test-schema.sh
#
# Exits non-zero if any assertion fails, so it can gate a schema change.
set -uo pipefail
cd "$(dirname "$0")/.."

# Git Bash rewrites container-internal paths without this.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# No default. A silent fallback would test a different Postgres than the node
# runs, which is worse than not testing: it reports PASS for the wrong thing.
IMAGE="$(awk '/^  postgres:/ {found=1} found && /image:/ {print $2; exit}' docker-compose.yml)"
if [ -z "$IMAGE" ]; then
  echo "could not read the postgres image from docker-compose.yml" >&2
  exit 1
fi
NAME="triage-schema-test-$$"

# Generated per run rather than written here. The container publishes no port and
# is removed on exit, so these only have to hold for the life of the test — but a
# literal in the file is one a secret scanner flags and a reader can mistake for a
# real credential. Same generator as install.sh, for the same reason it has one.
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

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

printf 'Schema tests on %s\n\n' "$IMAGE"

# Mounting db/init means the test exercises the real first-boot path, not a
# hand-maintained copy of the schema.
# TRIAGE_RO_PASSWORD and TRIAGE_COORD_PASSWORD are read by 03 and 04 through
# psql getenv to set the role passwords. Without them those files cannot run,
# and the test would silently cover less of the real first-boot path than it
# appears to.
docker run -d --name "$NAME" \
  -e POSTGRES_USER=triage_admin -e POSTGRES_PASSWORD="$PG_PW" -e POSTGRES_DB=n8n_primary \
  -e TRIAGE_RO_PASSWORD="$RO_PW" -e TRIAGE_COORD_PASSWORD="$COORD_PW" \
  -v "$(pwd -W 2>/dev/null || pwd)/db/init:/docker-entrypoint-initdb.d:ro" \
  "$IMAGE" >/dev/null || { echo "could not start $IMAGE"; exit 1; }

# 240s, not 120s. First boot runs all four init scripts, including the full
# schema, and then Postgres restarts before it accepts connections. On a busy
# machine 120s tipped over into a false "never became ready", which reads as a
# schema failure when nothing is wrong with the schema.
for _ in $(seq 1 120); do
  docker exec "$NAME" pg_isready -U triage_admin -d triage >/dev/null 2>&1 && break
  sleep 2
done
docker exec "$NAME" pg_isready -U triage_admin -d triage >/dev/null 2>&1 \
  || { echo "postgres never became ready"; docker logs --tail 30 "$NAME"; exit 1; }

# install.sh re-applies 02 on every run, so re-application must stay clean.
if docker exec -i "$NAME" psql -q -v ON_ERROR_STOP=1 -U triage_admin -d postgres \
     < db/init/02-triage-schema.sql >/dev/null 2>&1; then
  printf 'PASS  the schema re-applies cleanly (install.sh does this every run)\n'
else
  printf 'FAIL  the schema does not re-apply cleanly\n'
  exit 1
fi

docker exec -i "$NAME" psql -q -v ON_ERROR_STOP=1 -U triage_admin -d postgres < db/test-schema.sql
status=$?

printf '\n'
if [ "$status" -eq 0 ]; then
  printf 'Schema tests passed.\n'
else
  printf 'Schema tests FAILED.\n'
fi
exit "$status"
