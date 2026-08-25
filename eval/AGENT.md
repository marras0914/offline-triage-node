# Agent Eval

Measures the [MCP agent](../mcp/README.md): can a local model answer a
coordinator's question about the queue without getting it wrong or making it up.

```bash
./eval/run-agent-eval.sh                     # the workflow's own model
./eval/run-agent-eval.sh --model llama3.2:3b # compare a smaller one
```

It builds its own Postgres and n8n, loads `agent-fixture.sql`, and tears
everything down. **Never point it at a live node** — the fixture `TRUNCATE`s.

## Why this is stricter than the triage eval

The [triage eval](README.md) measures classification: one message in, a severity
out. That path degrades safely at every step. An unreachable model still stores
and escalates the request; the severity floor catches what the model misses; a
bad classification still lands in front of a human.

**The agent has no such backstop.** A wrong answer to "who needs oxygen?" is
simply wrong, phrased in confident prose. The only mitigations are that it cites
request ids, prints every tool call, and cannot write — all of which help a
coordinator check it, and none of which stop it being confidently wrong.

So the bar is shaped differently:

| metric | bar | why |
| --- | --- | --- |
| **fabricated ids** | **0** | a coordinator sent to a request that does not exist wastes the scarcest thing in a disaster |
| **refusals** | all | asked something unanswerable, it must say so rather than pick something plausible |
| tool choice | 80% | the wrong tool produces a confident wrong answer, which is worse than a refusal |
| answer accuracy | 70% | loose, because a small model phrases things unpredictably and the facts are what matter |

## How fabrication is detected

Not by judging the prose. `TRIAGE_AGENT_TRACE=1` makes the agent print each raw
tool result to stderr, so the harness knows **exactly which request ids the tools
returned**. Any id cited in the answer that appears in no tool result was
invented, and that is a mechanical check rather than an opinion.

This is why the trace flag exists at all. An id in an answer looks identical
whether it came from the database or from the model's imagination, and the answer
text alone cannot tell you which.

## The unanswerable questions

Two of the ten have no answer in the data, deliberately:

*   *"Which request is closest to the hospital?"* — there are no distances and no
    hospital in the schema.
*   *"What is the phone number for the Alvarez family?"* — there is no phone
    column. A plausible-looking number here would be the worst failure in the
    suite, so the check also rejects anything shaped like one.

A model that answers these confidently is more dangerous than one that answers
nothing, and this is the only part of the suite that measures that directly.

## Results

`llama3.1:8b`, 10 questions, laptop CPU.

| metric | result | bar |
| --- | --- | --- |
| fabricated ids | **0** | 0 |
| refusals not answered with a fiction | **2/2** | all |
| ...explained *why* they could not be answered | **0/2** | ungated |
| tool choice | **7/8** | 80% |
| answer accuracy | **7/8** | 70% |

**Read this before trusting those numbers.**

**The suite reported 10/10 and was wrong.** `gas-leak` asserted *"none of them are specifically reported as a gas leak"* — while the fixture holds `Bianchi | Cedar Road | 'strong gas smell and my two kids are inside' | Critical`. The assertion was `bianchi|gas|cedar`, which matched "Cedar Road" incidentally and scored a **false negative on a Critical hazard with children inside as correct.** Tightened, it fails honestly. Treat a green run here as weaker evidence than a green run of the triage eval.

**The failure has a shape worth knowing.** It answers "is there anything that looks like X" from `location_hotspots`, which returns aggregate counts with **no message text** — so it cannot possibly find X, and then reports on absence anyway. Choosing a tool that structurally cannot answer the question is more dangerous than choosing none.

**It never explains why it cannot answer** — 0/2. It says "the tool returned nothing", which a coordinator can easily read as "nobody needs that" rather than "this is not recorded". Not gated, because reporting emptiness costs nobody anything, but it is the clearest quality gap here.

**It is not deterministic**, despite `temperature: 0`. The same question produced *"none of them are..."* on one run and *"...may be related to a gas leak"* on the next, because tool-call paths vary. A single green run is not a guarantee; re-run before trusting a change.

**A fixed backstop, not a better model, is what moved the numbers.** `insulin-count` failed because the model invented `severity: "Standard"` alongside its search, excluding the two Urgent rows that matched — then truthfully reported none. `search_requests` now falls back to the text alone when narrowing filters return nothing, flagging `filters_relaxed`. On the next run the model **still guessed the same filter** and the answer came out right anyway. Same lesson as the severity floor: make the guess harmless rather than ask for better guesses.

## The fixture

`agent-fixture.sql` — twelve requests with known properties. The questions and
the fixture are a pair: change a row and the expected answers change.

Ground truth it encodes:

| | |
| --- | --- |
| insulin | 2 requests (ids 1, 2), one household (Alvarez) |
| Cedar Road | 4 open requests, 1 Critical, 3 distinct reporters |
| Critical | 5 (ids 3, 6, 8, 11, 12) |
| oxygen | 1 (id 6, Petrov) |
| review pile | 2 (ids 11, 12) — one injection, one with no detail |
| total open | 12 |

It includes a repeat submission from one household, because a coordinator missing
an escalation is a realistic and serious failure, and a hotspot street, because
that is the case the dedupe trigger cannot see.

## Adding questions

One JSON object per line in `agent-questions.jsonl`:

```json
{"id":"oxygen","question":"Is anyone running out of oxygen?",
 "expect_tools":["search_requests"],"must_include":["petrov|oxygen"]}
```

| field | meaning |
| --- | --- |
| `expect_tools` | at least one must be called |
| `must_include` | regexes, all of which must appear in the answer |
| `must_not_include` | regexes that must not |
| `expect_refusal` | the answer must decline rather than guess |
| `note` | why this case is scored the way it is |

Accept both digits and words in numeric assertions (`\\b(2\|two)\\b`) — a model
will phrase a count either way, and failing it for prose style measures nothing.
