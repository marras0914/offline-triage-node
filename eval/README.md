# Triage Eval

A regression suite for the thing this project cannot test by eye: whether the
local model, running the deployed prompt, sorts real human panic correctly.

Prompt engineering without a scoreboard is guesswork. Here it is worse than
guesswork, because the output decides who a coordinator reaches first.

## Running it

```bash
./eval/run-eval.sh                    # full set, the workflow's own model
./eval/run-eval.sh --tag noise        # only the noise cases
./eval/run-eval.sh --model phi3       # compare a candidate model
./eval/run-eval.sh --json /tmp/e.json # machine-readable results
```

The wrapper runs the harness inside the n8n container, which already has node and
can resolve `ollama` internally — nothing extra to install on the node. From a
host with node and a reachable Ollama:

```bash
OLLAMA_URL=http://localhost:11434 node eval/run-eval.mjs --model llama3.2:1b
```

It exits non-zero when the run misses the bar, so a prompt change can be gated
the way a code change is.

## There is no second copy of the prompt

`run-eval.mjs` does not contain the prompt or the schema. It loads
`n8n/workflows/sos-intake-triage.json`, extracts the **Normalize Intake** node's
code, and executes that function to build each request. The harness therefore
tests whatever is deployed. Edit the prompt in the workflow and this suite tests
the edit; there is nowhere for the two to drift apart.

## The pass bar

Defined in `BAR` at the top of `run-eval.mjs`.

| metric | bar | why |
| --- | --- | --- |
| schema violations | 0 | `format` constrains decoding; any violation means the contract broke |
| **critical recall** | **100%** | a missed Critical is a person who does not get help |
| fabrications | 0 | see below |
| severity accuracy | 75% | queue ordering degrades gracefully; recall does not |
| category accuracy | 80% | wrong category misroutes to the wrong responder |

The harness runs **both** Code nodes — Normalize Intake and Validate Triage — so
the labels it scores are what would land in Postgres, after the deterministic
severity floor and injection check have had their say. Scoring the model's raw
answer alone would miss the safeguards that decide what a coordinator sees. The
schema metric is the exception: that is a contract about the model's own output,
so it is measured before validation. Reported alongside, ungated: how many rows
the floor raised, how many were flagged as injection, and how many would reach a
human via `needs_review`.

**Critical recall and over-escalation are not comparable errors.** A Standard
request read as Critical is noise in a coordinator's queue. A Critical request
read as Standard is someone waiting behind blankets. The bar is asymmetric on
purpose, and over-escalation is reported but never gated.

## Fabrication check

Applied only to cases marked `no_fabrication` — the noise inputs. Real messages
get paraphrased, and the check would false-positive on all of them.

It exists because of a confirmed defect: given `asdkjh ???? help ,,,, 111`, the
model produced *"Unconscious person needs medical attention."* There is no
unconscious person. Escalating unparseable input to Critical is correct;
inventing a casualty to justify it sends scarce medics to nobody.

The check collects words in the summary with no stem in the input, ignoring
framing language the model may legitimately add ("needs", "assistance",
"person"). On that example it flags `unconscious`, which is exactly the invented
clinical claim. Tracked as issue #10.

## The golden set

`golden-set.jsonl`, one case per line:

```json
{"id":"urg-med-01","message":"...","expect":{"severity":"Urgent","category":"Medical","people":1}}
```

| field | meaning |
| --- | --- |
| `severity`, `category` | the primary expectation, used for the confusion matrix |
| `severity_ok`, `category_ok` | also-acceptable answers for genuinely ambiguous cases |
| `people`, `people_ok` | expected `people_affected`; reported but not gated |
| `no_fabrication` | run the fabrication check on this case |
| `note` | why this case is labelled the way it is |

Ambiguity is labelled honestly rather than pretended away. `crit-str-01` is a man
trapped under a roof and bleeding: extraction has to precede treatment, so the
primary label is Structural, but Medical is accepted. Marking one of those wrong
would be scoring the rubric's ambiguity as a model failure.

Coverage includes chaotic all-caps panic, rambling multi-need messages, non-English
intake, and prompt injection — intake is a public, unauthenticated endpoint, so
`inject-*` cases check that instructions in the message body cannot override the
rubric.

## Baseline

First full run, `llama3.2:1b`, 42 cases. **1B is not the deployment model** — it was
chosen because a small model is a harsher test of whether `format` really
constrains decoding. Re-run on `llama3.1` 8B before reading anything here as
settled (issue #2).

| metric | before | after backstops | bar |
| --- | --- | --- | --- |
| schema violations | **0** | **0** | 0 |
| critical recall | 83.3% | **100%** | 100% |
| fabrications | 3 | 3 | 0 |
| severity accuracy | 64.3% | 66.7% | 75% |
| category accuracy | **88.1%** | **81.0%** | 80% |
| people_affected | 73.3% | 90.0% | ungated |

"After" is the same 42 cases with the deterministic backstops and prompt fencing
from issue #20 in place. What it settles and what it does not:

1. **Prompt injection is fixed.** Before: all three `inject-*` cases downgraded
   to Standard, and every missed Critical was an injection (15/15 on legitimate
   messages, 0/3 on injections). After: 18/18 Critical, with all three flagged
   and the floor raising `inject-01` outright. The fix is regex, so this result
   does not depend on the model — but the pattern lists are not exhaustive, and
   a Critical indicator outside the floor's vocabulary ("choking") is still
   reachable. Issue #20 stays open for coverage.
2. **Urgent is still never used.** All 13 Urgent cases came back Critical both
   times, so the three-level scale behaves as two and queue ordering has lost a
   tier. Unchanged by the prompt work, and the most likely small-model artifact
   here. Re-test at 8B before drawing conclusions.
3. **Fabrication is unchanged, and the pipeline does not catch it.** All three
   noise cases still invent a clinical detail — `"help"` alone yields *"life
   threatening injury requiring medical attention."* Worse, they arrive with
   valid enums, so nothing marks them `needs_review` and they reach a
   coordinator looking clean. The fabrication check lives in this harness, not
   in Validate Triage. Issue #10.
4. **Category accuracy fell 88.1% → 81.0%**, three cases, while
   `people_affected` rose 73.3% → 90.0%. Both plausibly noise at n=42 on a 1B
   model, but the prompt did change, so treat the category drop as unexplained
   until the 8B run.

Schema adherence is the one thing confirmed outright, twice: `format` constrains
decoding rather than merely requesting JSON.

## Adding cases

Field use is the best source. When a real request is misrouted, add it with the
label it should have had. That is how the suite gets teeth: it accumulates the
specific ways this model fails on this population's phrasing.

Keep the primary labels defensible to a coordinator, and prefer widening
`severity_ok` / `category_ok` over relabelling something obviously wrong.
