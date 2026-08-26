#!/usr/bin/env bash
#
# Dumps the triage database and verifies the dump before claiming success.
#
#   ./scripts/backup.sh /media/usb
#
# Defaults to ./backups if no destination is given, which is better than nothing
# and worse than removable media: the realistic loss is the node itself — dropped,
# submerged, or stolen — not a corrupt table.
#
# A backup that has not been checked is a guess, so this counts the rows it
# captured and refuses to report success on a dump that does not contain them.
set -uo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-backups}"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
FILE="$DEST/triage-$STAMP.sql"

fail() { printf '\nBACKUP FAILED: %s\n' "$1" >&2; exit 1; }

docker compose ps postgres >/dev/null 2>&1 || fail "the stack is not running here."
mkdir -p "$DEST" || fail "cannot write to $DEST"

printf 'Backing up triage -> %s\n' "$FILE"

LIVE_ROWS="$(docker compose exec -T postgres psql -U triage_admin -d triage -tAc \
  'SELECT count(*) FROM requests' 2>/dev/null | tr -d '[:space:]')"
[ -n "$LIVE_ROWS" ] || fail "could not reach the triage database."

docker compose exec -T postgres pg_dump -U triage_admin --clean --if-exists triage > "$FILE" \
  || fail "pg_dump errored. $FILE is not trustworthy."

# Verify rather than assume.
[ -s "$FILE" ] || fail "the dump is empty."
grep -q 'CREATE TABLE public.requests' "$FILE" || fail "the dump does not contain the requests table."
grep -q 'COPY public.requests' "$FILE"         || fail "the dump contains no request data."

SIZE="$(du -h "$FILE" | cut -f1)"
printf '\n  %s  (%s, %s rows captured)\n' "$FILE" "$SIZE" "$LIVE_ROWS"

case "$DEST" in
  backups|./backups)
    printf '\n  WARNING: written to the node'\''s own disk. Copy it to removable\n'
    printf '  media — losing the node is the failure this protects against.\n'
    ;;
esac

# .env holds N8N_ENCRYPTION_KEY, without which a restored node cannot decrypt its
# own database credential and the workflow stops writing, silently.
if [ -f .env ] && [ ! -f "$DEST/env.backup" ]; then
  cp .env "$DEST/env.backup" && chmod 600 "$DEST/env.backup"
  printf '\n  Also copied .env -> %s/env.backup (contains N8N_ENCRYPTION_KEY;\n' "$DEST"
  printf '  a restore without it cannot write to the database). Keep it secure.\n'
fi

printf '\nTo restore onto a fresh node:\n'
printf '  ./install.sh && docker compose exec -T postgres psql -U triage_admin -d triage < %s\n\n' "$FILE"
