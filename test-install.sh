#!/usr/bin/env bash
#
# Regression tests for the offline install path in install.sh.
#
#   ./test-install.sh
#
# Needs no Docker, no bundle and no network: it lifts the real code out of
# install.sh and runs it against fixtures. Both bugs it covers shipped in a
# bundle that built cleanly and could not be installed from, so the point is to
# fail here rather than on a node with no connection.
#
# Exits non-zero if any assertion fails.
set -uo pipefail
cd "$(dirname "$0")"

INSTALL_SH="${INSTALL_SH:-install.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $2, got $3)"; fi; }

printf 'Offline install tests against %s\n' "$INSTALL_SH"

# ---------------------------------------------------------------------------
# 1. model_present(): does the model-presence check agree with what `ollama
#    list` actually prints? It prints tagged names, so a bare model name from
#    the workflow is never in it literally. A prefix match looked right and
#    reported a correctly restored bundle as missing its own model.
printf '\nmodel_present()\n'

FN="$(sed -n '/^model_present() {$/,/^}$/p' "$INSTALL_SH")"
if [ -z "$FN" ]; then
  bad "could not extract model_present() from $INSTALL_SH"
else
  eval "$FN"
  FIXTURE=""
  # Stands in for the `docker compose exec ... ollama list` inside the function.
  docker() { printf '%s' "$FIXTURE"; }

  HDR='NAME               ID              SIZE      MODIFIED'
  present() { if model_present; then echo present; else echo absent; fi; }

  TRIAGE_MODEL=llama3.1
  FIXTURE="$HDR
llama3.1:latest    42182419e950    4.7 GB    2 days ago
"
  check "a bare workflow model name matches its :latest row" present "$(present)"

  TRIAGE_MODEL=llama3.1:8b
  FIXTURE="$HDR
llama3.1:8b        42182419e950    4.7 GB    2 days ago
"
  check "an explicitly tagged name matches its own row" present "$(present)"

  TRIAGE_MODEL=llama3.1
  FIXTURE="$HDR
mistral:latest     aaaaaaaaaaaa    4.1 GB    2 days ago
"
  check "a different model is not a match" absent "$(present)"

  TRIAGE_MODEL=llama3
  FIXTURE="$HDR
llama3.1:latest    42182419e950    4.7 GB    2 days ago
"
  check "a prefix of another model is not a match" absent "$(present)"

  TRIAGE_MODEL=llama3.1
  FIXTURE="$HDR
"
  check "an empty model list is not a match" absent "$(present)"

  FIXTURE=""
  check "no output at all is not a match" absent "$(present)"

  unset -f docker
fi

# ---------------------------------------------------------------------------
# 2. The bundle restore pipeline, run for real on a fixture archive built the
#    way scripts/make-offline-bundle.sh builds the model tarball. gunzip has
#    already decompressed the stream by the time tar sees it, so asking tar to
#    decompress again fails with "stdin: not in gzip format".
printf '\nbundle restore pipeline\n'

mkdir -p "$WORK/src/models/manifests/registry.ollama.ai/library/llama3.1"
echo fixture > "$WORK/src/models/manifests/registry.ollama.ai/library/llama3.1/latest"
echo blob > "$WORK/src/models/blob-sha256-test"

# Same command shape as make-offline-bundle.sh: tar -czf - -C <dir> .
tar -czf "$WORK/bundle.tar.gz" -C "$WORK/src" . \
  || bad "could not build the fixture bundle"

# The restore command lifted out of install.sh, with the container prefix and
# the container path swapped for local equivalents. If the flags in install.sh
# regress, this regresses with them.
RESTORE="$(grep -A1 'gunzip -c "\$BUNDLE/ollama-models.tar.gz"' "$INSTALL_SH" | tail -n1)"
case "$RESTORE" in
  *'tar -xf -'*) ok "install.sh restores with 'tar -xf' (not -xzf)" ;;
  *)             bad "unexpected restore command in $INSTALL_SH: $RESTORE" ;;
esac

mkdir -p "$WORK/dest"
if gunzip -c "$WORK/bundle.tar.gz" | tar -xf - -C "$WORK/dest" 2>"$WORK/err"; then
  ok "gunzip -c | tar -xf restores the archive"
else
  bad "gunzip -c | tar -xf failed: $(cat "$WORK/err")"
fi

if [ -f "$WORK/dest/models/manifests/registry.ollama.ai/library/llama3.1/latest" ]; then
  ok "the restored tree has the model manifest ollama reads at startup"
else
  bad "the model manifest is missing from the restored tree"
fi

# Locks in the reason for the flag: the old command genuinely cannot work.
if gunzip -c "$WORK/bundle.tar.gz" | tar -xzf - -C "$WORK/dest" 2>/dev/null; then
  bad "gunzip -c | tar -xzf unexpectedly succeeded; the -xf flag may no longer matter"
else
  ok "gunzip -c | tar -xzf still fails, which is why -xf is required"
fi

# ---------------------------------------------------------------------------
# 3. Both scripts must read the model name from the same place, or a bundle can
#    be built for one model and verified against another.
printf '\nmodel name source\n'

EXPR='DEFAULT_MODEL'
a="$(grep -c "$EXPR" install.sh)"
b="$(grep -c "$EXPR" scripts/make-offline-bundle.sh)"
if [ "$a" -ge 1 ] && [ "$b" -ge 1 ]; then
  ok "install.sh and make-offline-bundle.sh both read $EXPR from the workflow"
else
  bad "the two scripts no longer agree on where the model name comes from"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
