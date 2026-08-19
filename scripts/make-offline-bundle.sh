#!/usr/bin/env bash
#
# Builds a self-contained bundle so the node can be installed with no internet.
#
# Run this on a machine that HAS a connection, ahead of time. Copy the whole
# repository — including the offline-bundle/ directory this produces — onto a USB
# stick. install.sh finds the bundle and loads from it instead of pulling.
#
# The bundle is a set of exact versions, which is why the images in
# docker-compose.yml have to be pinned. A `:latest` tag cannot be bundled
# meaningfully: you would be shipping "whatever was current the day I ran this"
# with no way to tell what that was.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE="${BUNDLE_DIR:-offline-bundle}"
WORKFLOW_FILE="n8n/workflows/sos-intake-triage.json"

fail() { printf '\nError: %s\n' "$1" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker is not installed."
docker info >/dev/null 2>&1 || fail "the Docker daemon is not running."

# The workflow is the single source of truth for the model, same as in install.sh.
MODEL="$(grep -oE "DEFAULT_MODEL = '[^']+'" "$WORKFLOW_FILE" | head -n1 | cut -d"'" -f2)"
[ -n "$MODEL" ] || fail "could not read DEFAULT_MODEL from $WORKFLOW_FILE"

# Pinned images, read from compose rather than duplicated here.
IMAGES="$(grep -oE '^[[:space:]]+image:[[:space:]]*[^[:space:]]+' docker-compose.yml | awk '{print $2}')"
[ -n "$IMAGES" ] || fail "no images found in docker-compose.yml"

printf '========================================================\n'
printf '  Building offline bundle\n'
printf '========================================================\n'
printf '  model : %s\n  images:\n' "$MODEL"
for i in $IMAGES; do printf '    %s\n' "$i"; done

mkdir -p "$BUNDLE"

# ---------------------------------------------------------------------------
printf '\n[1/4] Pulling images (needs a connection; this is the online step)...\n'
for image in $IMAGES; do
  printf '  %s\n' "$image"
  docker pull -q "$image" >/dev/null || fail "could not pull $image"
done

printf '\n[2/4] Saving images to a single archive...\n'
# One archive rather than one per image, so shared layers are stored once.
# shellcheck disable=SC2086
docker save $IMAGES | gzip -1 > "$BUNDLE/images.tar.gz" || fail "docker save failed"
printf '  %s\n' "$(du -h "$BUNDLE/images.tar.gz" | cut -f1) images.tar.gz"

# ---------------------------------------------------------------------------
printf '\n[3/4] Pulling and exporting the model...\n'
# A throwaway Ollama on its own volume, so this does not disturb a running node.
docker rm -f triage-bundle-ollama >/dev/null 2>&1 || true
docker volume create triage_bundle_models >/dev/null
docker run -d --name triage-bundle-ollama -v triage_bundle_models:/root/.ollama \
  "$(echo "$IMAGES" | grep ollama | head -n1)" >/dev/null || fail "could not start Ollama"

for _ in $(seq 1 60); do
  docker exec triage-bundle-ollama ollama list >/dev/null 2>&1 && break
  sleep 2
done
docker exec triage-bundle-ollama ollama pull "$MODEL" || fail "could not pull model $MODEL"

# Tar the Ollama data directory itself. Ollama's blob layout is what it reads at
# startup, so restoring the directory is enough — no re-import step needed.
docker exec triage-bundle-ollama tar -czf - -C /root/.ollama . > "$BUNDLE/ollama-models.tar.gz" \
  || fail "could not export the model"
printf '  %s\n' "$(du -h "$BUNDLE/ollama-models.tar.gz" | cut -f1) ollama-models.tar.gz"

docker rm -f triage-bundle-ollama >/dev/null
docker volume rm triage_bundle_models >/dev/null

# ---------------------------------------------------------------------------
printf '\n[4/4] Writing the manifest...\n'
{
  printf 'Offline bundle for the Edge Triage Node\n'
  printf 'built: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'model: %s\n\n' "$MODEL"
  printf 'images:\n'
  for image in $IMAGES; do
    printf '  %s\n' "$image"
    printf '    digest: %s\n' "$(docker image inspect "$image" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo 'unknown')"
  done
  printf '\nfiles:\n'
  (cd "$BUNDLE" && for f in images.tar.gz ollama-models.tar.gz; do
    [ -f "$f" ] && printf '  %-24s %s\n' "$f" "$(du -h "$f" | cut -f1)"
  done)
} > "$BUNDLE/MANIFEST.txt"
cat "$BUNDLE/MANIFEST.txt"

printf '\n========================================================\n'
printf '  Bundle ready: %s (%s total)\n' "$BUNDLE" "$(du -sh "$BUNDLE" | cut -f1)"
printf '========================================================\n'
printf '  Copy this whole repository, including %s/, to removable media.\n' "$BUNDLE"
printf '  On the target machine, ./install.sh will load from it and never\n'
printf '  touch the network.\n\n'
printf '  Rebuild it when the pinned versions change. A bundle with a stale\n'
printf '  image set is a bundle that fails on the day it is needed.\n'
printf '========================================================\n'
