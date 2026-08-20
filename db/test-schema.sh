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

IMAGE="$(grep -A1 '^  postgres:' docker-compose.yml | grep 'image:' | awk '{print $2}')"
IMAGE="${IMAGE:-postgres:17-alpine}"
NAME="triage-schema-test-$$"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

printf 'Schema tests on %s\n\n' "$IMAGE"

# Mounting db/init means the test exercises the real first-boot path, not a
# hand-maintained copy of the schema.
docker run -d --name "$NAME" \
  -e POSTGRES_USER=triage_admin -e POSTGRES_PASSWORD=test -e POSTGRES_DB=n8n_primary \
  -v "$(pwd -W 2>/dev/null || pwd)/db/init:/docker-entrypoint-initdb.d:ro" \
  "$IMAGE" >/dev/null || { echo "could not start $IMAGE"; exit 1; }

for _ in $(seq 1 60); do
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
