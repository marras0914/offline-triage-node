#!/usr/bin/env bash
#
# Terminal queue alarm. Leave it running in a window on the node.
#
#   ./scripts/watch-queue.sh
#   ./scripts/watch-queue.sh --interval 10
#
# The browser alarm on :8081 is the nicer one and the less reliable one: a tab
# can be muted, backgrounded, or on a locked screen, and browsers refuse to make
# noise until the page has been clicked. This has none of those failure modes. If
# you can only run one, run this.
#
# It reads the database directly rather than the HTTP endpoint, so it keeps
# working when n8n is the thing that is broken.
set -uo pipefail
cd "$(dirname "$0")/.."

INTERVAL=5
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="${2:-5}"; shift 2 ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

RED=$'\033[41;97;1m'; ORANGE=$'\033[43;30;1m'; GREEN=$'\033[42;30;1m'
DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'

# The terminal bell. Whether it makes a sound is a terminal setting, so the
# alarm never relies on it alone — the banner is the primary signal.
bell() { [ "$QUIET" = "1" ] && return; for _ in $(seq 1 "${1:-1}"); do printf '\a'; sleep 0.25; done; }

banner() { printf '\n%s  %-72s%s\n' "$1" "$2" "$OFF"; }

printf '%sTriage queue alarm — every %ss. Ctrl-C to stop.%s\n' "$BOLD" "$INTERVAL" "$OFF"
[ "$QUIET" = "1" ] && printf '%s(bell suppressed)%s\n' "$DIM" "$OFF"

LAST=""
while true; do
    ROW="$(docker compose exec -T postgres psql -U triage_admin -d triage -tAF'|' -c "
        SELECT critical_past_deadline, past_deadline, unacknowledged_critical,
               needs_review_open, model_failures_last_hour, injections_last_hour,
               coalesce(oldest_unacknowledged_min, 0), total_open, arrived_last_hour
        FROM queue_health" 2>/dev/null | tr -d '[:space:]')"

    STAMP="$(date '+%H:%M:%S')"

    if [ -z "$ROW" ]; then
        # Cannot read the queue. This is an alarm in its own right: a quiet
        # screen and an unreachable database look identical from here.
        banner "$RED" "CANNOT READ THE QUEUE — the alarm is blind  ($STAMP)"
        printf '   Check the node: docker compose ps && docker compose logs postgres\n'
        bell 3
        LAST="blind"
        sleep "$INTERVAL"
        continue
    fi

    IFS='|' read -r CRIT_LATE LATE UNACK_CRIT REVIEW MODEL_FAIL INJECT OLDEST OPEN ARRIVED <<< "$ROW"

    if [ "${CRIT_LATE:-0}" -gt 0 ]; then
        banner "$RED" "$CRIT_LATE CRITICAL PAST DEADLINE — nobody has picked them up  ($STAMP)"
        printf '   Oldest unacknowledged: %s min. Acknowledge and set assigned_to.\n' "$OLDEST"
        bell 5
        LAST="critical"
    elif [ "${MODEL_FAIL:-0}" -gt 0 ]; then
        # Not a queue problem. Requests are still stored and escalated, but
        # nothing is being sorted, so hand-triaging is the wrong response.
        banner "$ORANGE" "TRIAGE NOT RUNNING — $MODEL_FAIL request(s) stored untriaged this hour  ($STAMP)"
        printf '   Fix the node, do not hand-triage: docker compose logs ollama\n'
        [ "$LAST" = "model" ] || bell 2
        LAST="model"
    elif [ "${LATE:-0}" -gt 0 ]; then
        banner "$ORANGE" "$LATE past deadline — oldest $OLDEST min  ($STAMP)"
        [ "$LAST" = "late" ] || bell 2
        LAST="late"
    elif [ "${REVIEW:-0}" -gt 0 ] || [ "${UNACK_CRIT:-0}" -gt 0 ] || [ "${INJECT:-0}" -gt 0 ]; then
        printf '%s  %s  review:%s  unack critical:%s  injections:%s  oldest:%smin%s\n' \
          "$DIM" "$STAMP" "$REVIEW" "$UNACK_CRIT" "$INJECT" "$OLDEST" "$OFF"
        # No bell. These need working, not startling — a bell on every ordinary
        # queue state is how a room learns to ignore the bell.
        LAST="attention"
    else
        if [ "$LAST" != "ok" ]; then
            banner "$GREEN" "Queue is current — $OPEN open, $ARRIVED arrived this hour  ($STAMP)"
        else
            printf '%s  %s  clear — %s open, %s this hour%s\n' "$DIM" "$STAMP" "$OPEN" "$ARRIVED" "$OFF"
        fi
        LAST="ok"
    fi

    sleep "$INTERVAL"
done
