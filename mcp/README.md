# MCP Toolbelt

A read-only question-answering surface over the triage queue, for coordinators.

```bash
./scripts/ask.sh "how many people need insulin?"
./scripts/ask.sh "is anything happening on Cedar Road?"
./scripts/ask.sh "what is in the review pile and why?"
```

## What this is not

**It is not on the intake path, and it must never be.**

Intake keeps its own workflow and its own guarantee: if the model is unreachable, unbearably slow, or incoherent, the request is still stored, flagged, and escalated. That property is the reason this project works at all, and richer context is not worth trading it for. Nothing here runs while a request is being triaged.

**The original plan for this issue is already obsolete.** It was going to let the agent check whether a reporter had asked for aid before, so a second request arrived with prior context. A database trigger now does that ([#11](https://github.com/marras0914/offline-triage-node/issues/11)) — deterministically, on every insert path, with no model involved. A regex beat an agent, which is the right outcome and worth saying out loud.

So this got re-scoped to the thing an agent is actually good at: **letting a coordinator ask the queue a question in words.** "Who needs oxygen?" is genuinely awkward in NocoDB's filters and trivial in a sentence.

## The tools

Six, all read-only, all fixed queries:

| tool | for |
| --- | --- |
| `queue_summary` | overall load — how far behind, whether triage is even running |
| `search_requests` | find needs by the words people actually wrote |
| `get_request` | one request, plus every other submission from that reporter |
| `requests_by_reporter` | history for a household, including resolved |
| `location_hotspots` | open requests grouped by place, more than one only |
| `review_pile` | flagged rows, bucketed by why, where the summary is untrustworthy |

`location_hotspots` earns its place. The dedupe trigger groups by *reporter*, so it cannot see three **different** households reporting from one street — which usually means a structural cause nobody's individual request describes. In testing it surfaced `Cedar Road: 4 requests, 1 critical, 3 reporters` from rows that looked unrelated one at a time.

## Why it cannot damage the queue

Three layers, none of which relies on the model behaving:

1. **The model never writes SQL.** It picks a tool and fills in parameters; the SQL is fixed in `n8n/workflows/mcp-tools-api.json`. A small model composing its own queries on a 2-core node is a denial of service against the thing that is also trying to triage.
2. **Parameters are constrained.** Enums are whitelisted, limits clamped to 100, ids parsed as integers, and text is escaped into a literal. Verified against `x'; DROP TABLE requests; --` and friends.
3. **The database refuses to write.** Queries run as `triage_ro`, which holds `SELECT` on four relations and nothing else, with `default_transaction_read_only`, a 5s `statement_timeout`, and no access to `request_events` (who acknowledged what is a staffing record, not context for an answer).

Layer 3 is the one that matters, because it holds even if 1 and 2 are wrong. Tested directly:

```
INSERT INTO requests ...     REFUSED  cannot execute INSERT in a read-only transaction
UPDATE requests SET ...      REFUSED  cannot execute UPDATE in a read-only transaction
DELETE FROM requests         REFUSED  cannot execute DELETE in a read-only transaction
DROP TABLE requests          REFUSED  cannot execute DROP TABLE in a read-only transaction
CREATE TABLE evil (x int)    REFUSED  cannot execute CREATE TABLE in a read-only transaction
SELECT * FROM request_events REFUSED  permission denied for table request_events
```

## Shape of it

```
scripts/ask.sh
  └─ mcp/agent.mjs          Ollama tool-calling loop  (the offline MCP client)
       └─ mcp/server.mjs    MCP server, JSON-RPC over stdio
            └─ n8n MCP Tools API  →  Postgres as triage_ro
```

`server.mjs` is a standard MCP server, so any stdio-speaking MCP client can drive it. `agent.mjs` exists because the usual clients assume a hosted model over the internet, which this node will not have.

**Zero dependencies, both files.** `npm install` does not work during a blackout, and a `node_modules` tree is one more thing to get into the offline bundle and keep in step. Node 18+ has everything needed.

**Neither needs node on the host.** They run inside the n8n container, which already carries it. This was not a stylistic choice: the NUC this was tested against has no host node at all.

## Reading the answers

The agent prints each tool call to stderr as it goes:

```
  [queue_summary {}]
  [search_requests {"text":"insulin"}]
```

That is deliberate. An agent whose reasoning is invisible cannot be checked, and this one must be checkable. Answers cite request ids so a coordinator can go and read the rows.

**It is an aid for reading a queue, not an authority on who gets help first.** Same standing as the AI triage itself, for the same reason.

## Limits worth knowing

*   **A small model will misread a hard question.** It is much easier to classify one message than to reason across a queue, so expect worse behaviour here than the triage eval numbers suggest — those measure classification, not question answering. The agent has its own suite: [eval/AGENT.md](../eval/AGENT.md), which gates fabrication at zero and requires it to decline questions the data cannot answer.
*   **No pagination.** Every tool caps at 100 rows, so on a large queue an answer may be drawn from a slice. `queue_summary` gives true totals.
*   **English only**, like the rest of the tooling. The severity floor covers Spanish; this does not.
*   **It cannot act.** No acknowledging, assigning, or dispatching — by design, and by grant.
