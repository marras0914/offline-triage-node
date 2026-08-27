# A triage node for the hours when nothing answers

Most disaster software assumes the disaster spared the network. This one doesn't.

The Edge Triage Node is a self-hosted box that broadcasts its own Wi-Fi, serves an SOS intake form to anyone who connects, runs a local language model to sort what comes in by severity, and files it into a dashboard a human coordinator can work. It needs no internet, no cell service, and no upstream anything. It is built for the hours between the infrastructure failing and it coming back — the window when a community can still help itself but has lost the ability to organise.

It is not a substitute for emergency services. Where any emergency number still answers, call it.

## What it actually is

Five containers, pinned to exact versions:

- **nginx** serves the intake form on port 80 and proxies the submission endpoint. Port 80 is the only thing a survivor's phone ever touches.
- **n8n** runs the intake workflow: parse, classify, store.
- **Ollama** runs the model locally. `llama3.1` 8B by default.
- **Postgres** holds every request, plus an audit trail of who looked at what.
- **NocoDB** gives coordinators a sortable dashboard over that Postgres, with no application code of its own.

A phone joins the SSID, the captive portal opens the form, someone types whatever they can manage under stress, and it becomes a row with a severity, a category, and their own words preserved verbatim.

## The one design decision that matters

**The AI sorts the queue. It was never what makes the queue exist.**

Everything else follows from that. If Ollama is missing, out of memory, or too slow, the pipeline does not break: the request is stored anyway, with the person's own words intact, marked `needs_review`, and defaulted to Critical so it surfaces at the top rather than the bottom. That is the same path that handles a crashed model, and it is verified end to end rather than assumed.

What you are left with when the AI is gone is a networked intake form feeding a sortable offline dashboard. No triage, but no lost requests either. Set against a clipboard and shouting, that is most of the value.

This is also why the model is constrained by code rather than by prompting. Three examples, each of which started as a real failure:

- **A severity floor.** Prompt injection in a message body could bury a Critical request. Asking the model more nicely did not fix it; a deterministic floor over the classification did, taking recall on Critical cases from 83.3% to 100%. Worth stating plainly: the floor’s vocabulary was grown from those same cases, so the suite guards against losing that coverage rather than proving it generalises to language nobody has seen yet. Only real intake tests that.
- **The summary is the person's own words.** Fed pure gibberish, the model once produced *"Unconscious person needs medical attention."* A message with almost no content cannot be summarised, so now it isn't — the stored summary is the raw text. Fabrications reaching a coordinator went from 3 to 0.
- **Unclassifiable means Critical, flagged.** Anything the model cannot place is escalated for a human, not filed quietly.

Every local-model failure in this project was fixed by a deterministic backstop, and none by a better prompt.

## What the hardware actually needs

Measured on two real machines, CPU only, no GPU acceleration anywhere, using the project's own 53-case eval suite:

| Machine | Model | p50 | p90 | Worst | Eval |
| --- | --- | --- | --- | --- | --- |
| NUC — i5-7260U, 2c/4t, 2017, native Linux | `llama3.2:3b` | **6.2s** | 7.0s | 25s | passes every gate |
| NUC — same | `llama3.1:8b` | **14.0s** | 16.1s | 57s | passes every gate |
| Laptop — i7-13700H, 14c/20t, Docker Desktop on Windows | `llama3.1:8b` | 12.0s | 15.7s | 64s | passes every gate |
| Laptop — same | `llama3.2:1b` | 4.8s | 7.7s | 15s | **fails** |

Three things fell out of that, and the first was a surprise.

**Core count matters far less than expected.** A two-core i5 from 2017 runs the full 8B model within 17% of a fourteen-core i7 from 2023. Inference at this size is memory-bandwidth bound, not core bound — and the laptop pays a virtualisation tax the NUC does not, because Docker Desktop on Windows runs through WSL2 while the NUC runs Docker natively. The OS is worth more than the silicon. If you have a choice, run Linux.

**Do not go below 3B.** The 1B model satisfies the JSON schema contract perfectly and fails at the actual job, marking everything Critical. A queue where every row is top priority is a queue you have to read end to end, which is the thing this system exists to avoid.

**Throughput is the real limit, not latency.** Ollama serialises requests, so at ~14s each, one node handles roughly four submissions a minute before a queue forms. The concurrency caps in nginx shed load rather than letting fifty people wait behind each other. That ceiling, not speed, is the argument for better hardware.

## Installing it where there is no internet

This is the part that took the most work to make real, because the node's whole premise is that you cannot download anything when you need it.

`scripts/make-offline-bundle.sh` runs on a machine that *does* have a connection and stages everything onto removable media: all six pinned images in one archive, plus the model's Ollama data directory. About 12.7 GB uncompressed, so use a 32 GB stick — one too full to rebuild a bundle on is one that fails you in the field. On the target machine, `./install.sh` finds the bundle, loads from it, and never touches the network.

Triage quality survives the trip: the 53-case eval was re-run against a model restored from a bundle rather than pulled over the network, and every gate came out identical to the published baseline. The builder now reads both archives back before it finishes, checking that every pinned image is really inside and that the model's manifest is present under the exact name the installer will look it up by. That check exists because a bundle once built perfectly and could not be restored at all, which is [its own story](the-install-that-could-never-work.md).

## What is not true yet

The software is essentially complete and tested. **Nothing has been validated on deployed hardware in a field, or on a real handset.**

Verified, on developer machines: triage quality across 53 cases with 100% recall on the 29 Critical ones; 31 schema assertions; 17 portal offline-behaviour tests; the agent's question answering with zero fabricated request ids; the hardware floor above; and, as of this week, the air-gapped install end to end.

Not verified: captive portal detection on any real phone, VLAN and mesh behaviour, power draw over 72 hours, and a clean boot on the prepositioned target hardware. Those need a field, a handset, and a battery, and no amount of further desk work substitutes for them.

If you have a mini-PC, a router you can configure, and an afternoon, the thing that would help most is telling us what breaks.

**Repository:** <https://github.com/marras0914/offline-triage-node>
