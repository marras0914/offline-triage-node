# Operations Runbook

For the people working the queue while the node is running.

## The only thing on this page that is not optional

**Name a person.** The pipeline escalates anything it cannot classify to Critical and flags it for review. If nobody is assigned to read the flagged rows, all of that machinery is decorative — a request is marked urgent and then sits there.

Everything below assumes one named human is watching. If you cannot staff that, say so out loud when you deploy, because the system's central safety promise is not being kept.

## Roles

| Role | Owns | Needs |
| --- | --- | --- |
| **Queue watcher** | `active_queue`, `review_pile`. Acknowledges, assigns, dispatches. | NocoDB on :8080 |
| **Node operator** | The node is up, the model answers, the disk is not full, backups exist. | Shell on the node |
| **Shift lead** | Handover, staffing, deciding when the node is the problem. | Both |

One person can hold all three in a small deployment. If you must drop one, drop the shift lead — but then the queue watcher runs the hourly node check themselves, because a node that has quietly stopped triaging looks exactly like a quiet hour.

## The alarm

Start one of these at the beginning of a shift. They watch the queue so nobody has to remember to.

**In a terminal on the node** — the reliable one:

```bash
./scripts/watch-queue.sh
```

**On a coordinator's screen** — `http://<NODE_IP>:8081/`, then **click "Arm the alarm"**.

Both read the same thresholds, so they cannot disagree about what counts as an alarm.

| Level | Condition | Behaviour |
| --- | --- | --- |
| **critical** | A Critical request past its 15-minute deadline, or the queue cannot be read at all | Repeating siren, flashing red |
| **warning** | Triage is not running, or requests are past deadline | Sounds once per change |
| **attention** | Flagged requests waiting, new Criticals inside deadline, suspected injection | Quiet chime |
| ok | Nothing outstanding | Silent green |

Three things about it that are deliberate:

*   **An unreachable node raises the alarm rather than showing green.** A blind alarm and a quiet queue look identical, so the page refuses to look calm when it cannot see. "ALARM IS BLIND" means work the queue directly and go fix the node.
*   **"Silence 2 min" silences the noise, never the condition.** The colour, headline and counts stay, and the sound comes back by itself.
*   **Only `critical` repeats.** A bell on every ordinary queue state is how a room learns to ignore the bell.

### The browser alarm is the one that will let you down

Read this before relying on it. A browser tab **cannot make a sound until the page has been clicked** — so an unarmed page is a silent alarm that looks like a working one. That is why there is a red bar across the top until you arm it, and a "Test sound" button. Use it; do not assume.

It is also defeated by a muted tab, a locked screen, or a browser the OS suspended in the background. It asks for a screen wake lock, which the browser may refuse.

`scripts/watch-queue.sh` has none of those failure modes, and it reads the database directly rather than through the API — so it keeps working when n8n is the broken thing. **If you only run one, run that.** Neither is a substitute for a physical siren, which does not exist yet ([#12](https://github.com/marras0914/offline-triage-node/issues/12)).

## The checks

The alarm tells you when to look. These are what you look at.

### Continuously — is anything past its deadline?

```sql
SELECT id, severity, minutes_open, reporter_name, location_text, summary
FROM active_queue WHERE past_deadline;
```

Anything here has waited longer than its severity allows and nobody has acknowledged it. Deadlines are **15 minutes for Critical, 1 hour for Urgent, 4 hours for Standard** — provisional numbers, set in `triage_ack_deadline()`.

This should normally be empty. A non-empty result is not "we are busy", it is "we have lost track".

### Every 15 minutes — work the review pile

```sql
SELECT id, reason, minutes_open, reporter_name, raw_message FROM review_pile;
```

Ordered so the rows a human must personally read come first. **Read `raw_message`, not `summary`** — for two of these reasons the summary is precisely what cannot be trusted.

| `reason` | What happened | What to do |
| --- | --- | --- |
| **Suspected injection** | The message contained instruction-shaped text. Triage output was discarded and severity forced to Critical. | Read the raw text yourself and triage by hand. Usually a forwarded message or pasted form letter; occasionally someone trying to move their request up the queue. |
| **Fabricated summary** | The model asserted a detail with no basis in a near-empty message. The summary was replaced with the person's own words. | Triage from `raw_message`. There is nothing else to go on — do not dispatch on the discarded summary. |
| **No detail given** | The message carries no triageable content ("help", punctuation). Escalated because a guess is not triage. | Try to make contact. Someone typing only "help" may be unable to type more. |
| **Floor overrode triage** | The message matched a Critical keyword but triage rated it lower. The keyword wins. | Confirm quickly and dispatch. The floor is deliberately blunt, so a few of these will be over-escalations — that is the trade. |
| **Incomplete submission** | A required field was blank. Stored anyway rather than refused. | Contact if you can; a name and an injury with no address is still actionable. |
| **Unrecognised value** | The model returned a severity or category outside the schema. | Classify by hand. |
| **Model unavailable** | Triage never ran. The row was stored and escalated by the fail-safe. | **This is a node problem, not a queue problem.** See below. |

### Hourly — is the node keeping up, or broken?

```sql
SELECT * FROM queue_health;
```

| Column | What it tells you |
| --- | --- |
| `unacknowledged_critical` | The number that matters. Should trend to zero. |
| `critical_past_deadline` | Should be zero. Anything else is the alarm condition. |
| `model_failures_last_hour` | **If this is climbing, stop hand-triaging and fix the node.** |
| `injections_last_hour` | A sustained rise means someone is working at the queue deliberately. |
| `arrived_last_hour` vs `dispatched_open` | Arrival rate against throughput. If arrivals exceed what you can dispatch, you need more coordinators, not more checking. |
| `oldest_unacknowledged_min` | The single worst case right now. |

### Once per shift — back up and hand over

```bash
./scripts/backup.sh /media/usb
```

Then the handover, below.

## When the node is the problem

`model_failures_last_hour` climbing means Ollama is unreachable, out of memory, or too slow. Every request is still being stored and escalated — nothing is being lost — but nothing is being sorted either, so the queue is arriving as a flat pile of Criticals.

The mistake here is to keep hand-triaging. Fix the node:

```bash
docker compose ps                       # is ollama up?
docker compose logs --tail 50 ollama
docker compose exec ollama ollama list  # is the model still there?
free -h                                 # did it get OOM-killed?
docker compose restart ollama
```

If the model will not load in the RAM available, switch to a smaller one — edit `DEFAULT_MODEL` in `n8n/workflows/sos-intake-triage.json`, re-run `./install.sh`, and re-run `./eval/run-eval.sh` to see what you gave up. Intake keeps working throughout; a node with no model is still a working intake form and dashboard.

## Status lifecycle

What the values mean in practice, not just in the CHECK constraint:

| Status | Means | Set it when |
| --- | --- | --- |
| `New` | Nobody has looked. | Automatic on intake. |
| `Acknowledged` | A human has read it and owns it. | You read it — **and set `assigned_to` at the same time.** |
| `Dispatched` | Someone is physically going. | Help is actually moving, not planned. |
| `Resolved` | The need was met, or confirmed no longer needed. | Not "we tried". Leave it open if you tried and failed. |
| `Duplicate` | Redundant against another row. | You have read both and are certain. |

Two rules that make the queue trustworthy:

*   **Acknowledged without `assigned_to` is worse than New**, because it hides the row from the past-deadline check while nobody owns it.
*   **Repeat submissions are linked, never hidden.** A non-zero `other_submissions` means this reporter has sent before — read the cluster together, because later messages are usually escalations. Only `status = 'Duplicate'` removes a row from the queue, and only a human sets that.

## Shift handover

```sql
-- What changed on this shift, and who moved it
SELECT e.at, e.request_id, e.field, e.old_value, e.new_value, e.assigned_to
FROM request_events e WHERE e.at > now() - interval '8 hours' ORDER BY e.at DESC;

-- Anything claimed but never finished
SELECT id, severity, assigned_to, status, minutes_open FROM active_queue
WHERE status IN ('Acknowledged','Dispatched') ORDER BY minutes_open DESC;
```

Hand over, out loud: everything in the second query by name, the current `queue_health` row, and whether the node has been fully triaging or falling back.

`request_events` records what changed and when. It records the *database* user, which is the same for everyone working through NocoDB — so attribution to a person depends entirely on coordinators setting `assigned_to`. It is a discipline, not a guarantee.

## Backups

The field data is one database. `scripts/backup.sh` dumps it, verifies the dump is non-empty and contains the `requests` table, and reports the row count it captured.

*   **Once per shift, and before any `install.sh` re-run.**
*   **Onto removable media**, not the node's own disk. The realistic loss here is the node — dropped, submerged, or stolen — not a corrupt table.
*   **Back up `.env` alongside it, once.** `N8N_ENCRYPTION_KEY` is load-bearing: without it a restored node cannot decrypt its own database credential and the workflow silently stops writing.

## What this runbook does not give you

Stated plainly so nobody discovers it during an incident:

*   **Nothing reaches you away from the node.** The alarm makes noise on the machine it runs on and nowhere else — no paging, no radio, no siren in the next room. Someone has to be within earshot of a laptop. A physical siren or strobe driven off a breach is [#12](https://github.com/marras0914/offline-triage-node/issues/12).
*   **The browser alarm is silent until armed**, and a locked or muted phone defeats it entirely. See above; prefer the terminal watcher.
*   **The deadlines are judgement calls**, not measurements from a real incident. Change them in `triage_ack_deadline()` once you have evidence.
*   **Attribution is by discipline.** See handover, above.
*   **No shift scheduling, no escalation tree, no comms plan.** Those belong to whoever is actually deploying, and depend on the responders they have.
