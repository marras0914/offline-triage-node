#!/usr/bin/env bash
#
# Ask the queue a question in plain language.
#
#   ./scripts/ask.sh "how many people need insulin?"
#   ./scripts/ask.sh "is anything happening on Cedar Road?"
#   ./scripts/ask.sh "what is in the review pile and why?"
#
# Runs inside the n8n container, which already carries node — so the host needs
# nothing installed. Read-only throughout: the database role the queries run as
# cannot write.
#
# An aid for reading the queue, never the authority on who gets help first. Every
# answer cites request ids; go and read them.
set -uo pipefail
cd "$(dirname "$0")/.."

if [ $# -eq 0 ]; then
  sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

docker compose ps n8n >/dev/null 2>&1 || { echo "the stack is not running here." >&2; exit 1; }

# The model is the one the workflow triages with, unless overridden. Answering a
# coordinator's question is harder than classifying one message, so a model too
# small for triage will be worse here — see eval/README.md.
MODEL="${TRIAGE_AGENT_MODEL:-$(grep -oE "DEFAULT_MODEL = '[^']+'" n8n/workflows/sos-intake-triage.json | head -n1 | cut -d"'" -f2)}"

docker compose exec -T \
  -e "TRIAGE_AGENT_MODEL=$MODEL" \
  n8n node /mcp/agent.mjs "$@"
