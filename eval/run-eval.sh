#!/usr/bin/env bash
#
# Runs the triage eval inside the n8n container, which already has node and can
# resolve `ollama` over the internal Docker network. Nothing extra to install on
# the node itself.
#
#   ./eval/run-eval.sh                      # full set, workflow's own model
#   ./eval/run-eval.sh --tag noise          # just the noise cases
#   ./eval/run-eval.sh --model phi3         # compare a different model
#   ./eval/run-eval.sh --json /tmp/eval.json
#
# Exits non-zero when the run misses the pass bar, so it can gate a change to the
# prompt the same way a test suite gates a change to code.
set -euo pipefail
cd "$(dirname "$0")/.."

# Git Bash rewrites container-internal paths without this, so the path handed
# to docker below arrives as C:/Program Files/Git/... inside the container and
# nothing is found. A no-op on Linux, which is the target.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

docker compose exec -T n8n node /eval/run-eval.mjs "$@"
