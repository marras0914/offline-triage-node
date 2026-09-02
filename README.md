# Offline-First Edge Triage Node

This project is a self-hosted, offline-first disaster response computing node. It is designed to be deployed in environments where cellular and internet infrastructure has failed, providing a localized emergency mesh network, an automated SOS intake portal, and an AI-driven triage routing system.

## The Problem
When centralized infrastructure fails during a disaster, local communities lose the ability to coordinate rescues, request aid, and triage resources. 

## The Solution
A portable, battery-backed edge computing node that broadcasts a local Wi-Fi mesh. Users connect, are forced to a captive portal, and submit SOS requests. A local LLM processes the unstructured requests, categorizes them by severity, and routes them to offline databases and local medic dashboards.

## Quick start

Needs Docker Engine and the Compose v2 plugin, and a connection for this first install. For an install with no connection at all, stage a bundle first — [DEPLOYMENT.md §2](DEPLOYMENT.md#2-installing-with-no-internet).

```bash
git clone https://github.com/marras0914/offline-triage-node.git
cd offline-triage-node
./install.sh
```

The installer asks for the node's static IP, then boots the stack, applies the schema, provisions the model, imports and activates the triage workflow, and smoke tests portal → n8n → Ollama → Postgres before it exits. It is safe to re-run: an existing `.env` is preserved, so secrets are never rotated out from under a live database.

When it finishes:

| | |
| --- | --- |
| Portal | `http://<node-ip>/` — what a survivor sees, port 80 only |
| Dashboard | `http://<node-ip>:8080/` — NocoDB, for triage coordinators |
| n8n hub | `http://<node-ip>:5678/` — operators |
| Alarm screen | `http://<node-ip>:8081/` — leave open on a display, then click Arm |

Two things the installer cannot do for you: attach the `triage` database as a NocoDB data source ([§5](DEPLOYMENT.md#5-post-install-attach-the-triage-data-to-nocodb)), and configure the router's walled garden ([§6](DEPLOYMENT.md#6-router--walled-garden)). Start the queue alarm with `./scripts/watch-queue.sh`. Full guide: **[DEPLOYMENT.md](DEPLOYMENT.md)**.

## Verifying your clone

Three of these need neither the stack running nor a network, so they are worth running before you trust anything else. `test-schema.sh` needs Docker; the other two need nothing.

```bash
./test-install.sh          # 24 assertions on the offline install path
./db/test-schema.sh        # 39 schema assertions on a throwaway Postgres
node html/test-portal.mjs  # 17 portal offline-behaviour tests
```

The triage quality suite needs a node that is already up with a model loaded, and is the gate for any prompt or model change — see [eval/README.md](eval/README.md):

```bash
./eval/run-eval.sh         # 54 cases, 100% recall required on Critical
```

## Status

Pre-field-test. The software is essentially complete and tested; **nothing has been validated on deployed hardware or a real handset.** See the [roadmap board](https://github.com/users/marras0914/projects/2).

What is verified, on developer machines rather than in a field:

| | |
| --- | --- |
| Triage quality | 54 cases, `llama3.1:8b` passes every gate — 100% recall over 29 Critical, 0 under-escalation ([eval/](eval/)). Re-run 2026-08-27 against a model restored from an offline bundle rather than pulled: identical on every gate |
| Schema behaviour | 39 assertions, including that a household's *worse* follow-up is never hidden, that the coordinator dashboard cannot reach n8n's credential store or rewrite a triage result, and that the audit trail records who actually made an edit ([db/test-schema.sh](db/test-schema.sh)) |
| Portal offline behaviour | 17 tests — holds a request on the phone, never reports a false success ([html/test-portal.mjs](html/test-portal.mjs)) |
| Agent question answering | 10 questions, 0 fabricated ids, 7/8 facts ([eval/AGENT.md](eval/AGENT.md)) |
| Hardware floor | a 2-core 2017 i5 runs 8B at 14s median, passing every gate |

What is **not** verified: a clean boot on the target node, captive portal detection on any real phone, VLAN and mesh behaviour, and power draw. Those are Phases 1, 2 and 4 on the board, and no amount of further desk work substitutes for them.

**This is not a substitute for emergency services.** Where any emergency number still answers, call it. This node is built for the hours when nothing answers — and its AI triage is a queue-ordering aid for human coordinators, never an authority on who gets help first. Requests the model cannot classify are escalated to Critical and flagged for a human rather than filed automatically.

## Hardware

### The prepositioned build

What to buy if you are equipping a node deliberately, ahead of time:

*   **Compute (Mini-PC/NUC):** AMD Ryzen 7 8845HS (or Intel Core Ultra 7 155H) to provide sufficient iGPU compute for local AI inference.
*   **Memory:** 32GB Dual-Channel DDR5-5600 RAM (LLM inference is memory-bandwidth bound).
*   **Storage:** 1TB Gen 4 NVMe SSD.
*   **Networking:** Weather-resistant mesh access points (e.g., UniFi U6 Mesh) and a ruggedized PoE switch.
*   **Power:** LiFePO4 battery pack coupled with a pure sine wave inverter.

### Running on what is actually available

The list above is a target, not a gate. A blueprint for the hours after infrastructure fails is not much use if it starts with a shopping list, so the stack is built to degrade rather than refuse.

**The only hard constraint is RAM**, and only if you want AI triage. Everything else trades down.

| What you have | Model | What you get |
| --- | --- | --- |
| Prepositioned NUC, 32GB, iGPU | `llama3.1` 8B | The full design, with headroom for concurrent load |
| **Any 2-core machine from ~2017 with 16GB** | `llama3.1` 8B on CPU | **Full triage, every eval gate passed, 14s per request — measured** |
| 8GB | `llama3.2:3b` | Full triage at 6s; passes because the deterministic floor covers the model |
| 4GB, a Raspberry Pi, or no model at all | none | **Intake and dashboard, no AI** — see below |

Storage is not the constraint the spec implies: images and an 8B model come to roughly 13GB, so any disk with 20GB free will do.

### Measured, CPU only, on two real machines

Not estimates. This project's own [eval suite](eval/), 53 cases, no GPU acceleration anywhere.

| Machine | Model | p50 | p90 | Worst | Eval |
| --- | --- | --- | --- | --- | --- |
| **NUC** — i5-7260U, 2c/4t, 2017, native Linux | `llama3.2:3b` | **6.2s** | 7.0s | 25s | passes every gate |
| **NUC** — same | `llama3.1:8b` | **14.0s** | 16.1s | 57s | passes every gate |
| Laptop — i7-13700H, 14c/20t, Docker Desktop on Windows | `llama3.1:8b` | 12.0s | 15.7s | 64s | passes every gate |
| Laptop — same | `llama3.2:1b` | 4.8s | 7.7s | 15s | **fails** — every tier collapses to Critical |

Three things fall out of this, and the first was a surprise:

**Core count matters far less than expected.** A two-core i5 from 2017 runs the full 8B model within 17% of a fourteen-core i7 from 2023. Inference at this size is memory-bandwidth bound, not core bound — and the laptop pays a virtualisation tax that the NUC does not, because Docker Desktop on Windows runs through WSL2 while the NUC runs Docker natively. **The OS is worth more than the silicon here.** If you have a choice, run Linux.

**8B is the model, and older hardware can carry it.** 14s median for a form submission is unnoticeable to someone typing, and the request is stored regardless — nobody's request depends on inference finishing. The nginx proxy allows 300s and the n8n node 180s, so even the 57s worst case fits comfortably.

**Do not go below 3B.** 1B satisfies the JSON schema contract perfectly and fails at the actual job, marking everything Critical. A queue where every row is top priority is a queue you must read end to end, which is the thing this system exists to avoid. 3B is a genuine fallback: it passes every gate, at 6.2s, and it only does so because the [deterministic severity floor](ARCHITECTURE.md#deterministic-backstops) catches what a smaller model misses. The backstops are what make weak hardware viable.

Those figures are model time, from the eval. A whole submission costs more: measured end to end through nginx, n8n, Ollama and Postgres on the laptop, 12.8-27.0s warm against 12.0s of model time. And the first submission after the model has been evicted from RAM cost 95-101s twice over, which is why the node now pins it resident (`OLLAMA_KEEP_ALIVE=-1`) instead of reloading 5.6GB at the worst possible moment.

Throughput is the real limit, not latency. Ollama serialises requests, so at ~14s each a single node handles roughly four submissions a minute before a queue forms; the concurrency caps in `nginx/default.conf` shed load rather than letting fifty people each wait behind it. **That ceiling — not speed — is the argument for the prepositioned build's iGPU.**

### The no-AI tier is real, not a consolation prize

If Ollama is missing, out of memory, or simply too slow, the pipeline does not break. Every request is stored with the person's own words preserved, marked `needs_review`, and defaulted to Critical so it surfaces at the top of the queue. This is the same fail-safe path that handles a crashed model, and it is [verified end to end](ARCHITECTURE.md#4-failure-behaviour) — not a theory about what might happen.

What that leaves you with is a networked intake form feeding a sortable, offline coordinator dashboard, running on almost anything. No triage, but no lost requests either, and a queue a human can work. Set against a clipboard and shouting, that is most of the value.

The AI sorts the queue. It was never what makes the queue exist.

### Phones are the clients, not the node

Everyone has one in their pocket, and that is the whole reason the captive portal exists: cellular dies early in a disaster, but Wi-Fi radios keep working, so a phone that can no longer call anyone can still reach a node fifty metres away. The portal holds a request in the phone's own storage and retries by itself, so walking to the edge of the mesh does not lose what someone typed.

Running the stack *on* a phone does not work, and it is worth knowing why before anyone tries: Docker is unavailable on stock Android; binding port 80 needs root, and a portal on :8080 is not a captive portal because OS detection probes go to :80; DNS hijacking needs root too; iOS has no general-purpose runtime at all. An old Android with Termux could run a stripped variant, but it still could not serve a captive portal. **A laptop is the smallest thing that can be the node.** See [#23](https://github.com/marras0914/offline-triage-node/issues/23).

### A laptop brings its own UPS

A laptop is a battery-backed server with a screen and a keyboard attached, which removes most of the power engineering from the ideal build for the first several hours. A phone power bank will usually carry a small router alongside it. The LiFePO4 pack matters for multi-day operation, not for getting started.

### Two things will genuinely stop you

Both are real gaps, tracked rather than glossed:

1.  **You cannot download anything during a blackout** ([#21](https://github.com/marras0914/offline-triage-node/issues/21)). `scripts/make-offline-bundle.sh` now stages every image and the model onto removable media, and `install.sh` loads from it without touching the network — but that bundle still has to be built *beforehand*, on a machine that has a connection, and that bundle has to be rebuilt whenever a pinned version changes. The install itself is now proven: it was run end to end with no network on 2026-08-27, and the builder verifies a bundle is restorable before you carry it anywhere.
2.  **A laptop hotspot still cannot serve a captive portal** ([#22](https://github.com/marras0914/offline-triage-node/issues/22)). The *router* half of this is now solved: `docker compose --profile captive-dns up -d` answers every hostname with the node, so a plain consumer router works — set its DHCP-advertised DNS to the node and detection fires. What remains is the laptop's own hotspot, where binding port 80 and controlling DNS both need privileges the OS does not hand out, and where client limits are typically around eight devices.

## Documentation

*   **[DEPLOYMENT.md](DEPLOYMENT.md)** — installing, including with no internet
*   **[OPERATIONS.md](OPERATIONS.md)** — running it: who watches the queue, the four checks, backups, handover
*   **[ARCHITECTURE.md](ARCHITECTURE.md)** — the stack, the data flow, and the deterministic safety backstops
*   **[mcp/README.md](mcp/README.md)** — the read-only toolbelt for asking the queue questions
*   **[eval/README.md](eval/README.md)** — the triage regression suite and what it does and does not prove
*   **[CONTRIBUTING.md](CONTRIBUTING.md)** — where help is needed

Longer reads:

*   **[A triage node for the hours when nothing answers](docs/an-offline-triage-node.md)** — what this is, what the hardware really needs, and what is not true yet
*   **[Four checks that could never fire](docs/the-install-that-could-never-work.md)** — the offline install failed four ways the first time it ran, and every one was the same mistake

## Roadmap

Four phases from local proof-of-concept to deployable field unit. Each phase is a [milestone](https://github.com/marras0914/offline-triage-node/milestones); progress is tracked on the [roadmap board](https://github.com/users/marras0914/projects/2).

### Phase 1 — Software Sandbox Validation

*Ensure the Docker stack boots reliably and the core data flow operates correctly, before introducing network complexity.*

- [ ] [Cluster initialization](https://github.com/marras0914/offline-triage-node/issues/1) — `./install.sh` brings all five containers up healthy, unattended, and is safe to re-run
- [ ] [Model provisioning](https://github.com/marras0914/offline-triage-node/issues/2) — `llama3.1` pulls into Ollama and answers within the iGPU's latency budget
- [ ] [Database initialization](https://github.com/marras0914/offline-triage-node/issues/3) — the three databases come up and NocoDB attaches `triage` as a data source
- [ ] [Pipeline routing test](https://github.com/marras0914/offline-triage-node/issues/4) — cURL the webhook and confirm the request is parsed, classified, and inserted

Partially verified already, on a dev box rather than target hardware: the schema and its queue ordering on Postgres 17, the fail-safe storage path, partial-submission flagging, empty-POST rejection, workflow import and activation, and Ollama's schema-constrained decoding. What remains needs the NUC.

Also in this phase, from review rather than the original plan:

- [x] [Pin all image tags](https://github.com/marras0914/offline-triage-node/issues/17) — all six pinned to exact patch versions, each verified rather than assumed. A stale `ollama:latest` at 0.19.0 had been sitting in a local cache while 0.32.15 was current, so earlier benchmarks ran against a version nobody had chosen
- [x] [Offline bootstrap](https://github.com/marras0914/offline-triage-node/issues/21) — `scripts/make-offline-bundle.sh` stages every image and the model (~12.7GB, so a 32GB stick); `install.sh` loads from it without touching the network. Run end to end with no network on 2026-08-27: images loaded from the bundle, the model restored from media, a live submission classified by it. Four bugs found in the attempt, all fixed and covered by `./test-install.sh` ([write-up](docs/the-install-that-could-never-work.md))
- [x] [Coordinator runbook](https://github.com/marras0914/offline-triage-node/issues/18) — [OPERATIONS.md](OPERATIONS.md), plus the `review_pile` / `queue_health` views and an audit trail so "nobody looked" is visible rather than silent
- [x] [Rate limiting](https://github.com/marras0914/offline-triage-node/issues/19) — per-device and global caps in nginx, and a shed request is told so in readable JSON. Measured 2026-08-27 rather than guessed: 12 concurrent submissions from one device yield 2 accepted and 10 rejected in ~16ms, and 10 concurrent from 5 devices yield exactly 8 accepted. The global cap of 8 is now derived from the model timeout divided by measured service time rather than picked

### Phase 2 — Network Isolation & Captive Portal

*Move off the standard LAN and prove the offline DNS hijacking and mobile UI work as intended.*

- [ ] [VLAN configuration](https://github.com/marras0914/offline-triage-node/issues/5) — isolated guest VLAN broadcasting the open `EMERGENCY-TEST` SSID
- [ ] [Walled garden](https://github.com/marras0914/offline-triage-node/issues/6) — pre-authorization access to the NUC on **port 80 only**; survivors never touch 5678 or 8080
- [ ] [Captive portal redirect](https://github.com/marras0914/offline-triage-node/issues/7) — a phone joins and the OS opens the form by itself
- [ ] [End-to-end mobile test](https://github.com/marras0914/offline-triage-node/issues/8) — a chaotic SOS from a handset arrives as a clean row in NocoDB
- [ ] [Phone-side resilience](https://github.com/marras0914/offline-triage-node/issues/23) — the portal now holds a request in the phone's own storage and retries with backoff ([17 tests](html/test-portal.mjs)). A service worker for locked-screen delivery, and what captive webviews actually permit, both need real handsets
- [ ] [Captive portal without a capable router](https://github.com/marras0914/offline-triage-node/issues/22) — solved for a consumer router: `--profile captive-dns` answers every hostname with the node, so only its DHCP-advertised DNS needs setting. The laptop-hotspot path probably cannot be solved

### Phase 3 — AI Hardening & Custom Tooling

*Prevent the local agent from hallucinating under stress, and extend the system's logic.*

- [x] [Chaos testing](https://github.com/marras0914/offline-triage-node/issues/9) — 42-case golden set and a regression harness that loads the deployed prompt, so a prompt edit is tested by definition ([eval/](eval/)). Baselined; still to re-run at 8B
- [x] [Prompt injection can bury a Critical request](https://github.com/marras0914/offline-triage-node/issues/20) — confirmed, then closed by a deterministic severity floor covering all 29 Critical cases; recall 83.3% → 100%. Open only for growing the floor’s vocabulary from real intake
- [x] [Model invents injuries from noise](https://github.com/marras0914/offline-triage-node/issues/10) — pure gibberish produced *"Unconscious person needs medical attention."* A message with almost no content cannot be summarised, so the stored summary is now the person’s own words. Fabrications reaching a coordinator: 3 → 0
- [x] [Deduplicate rapid-fire requests](https://github.com/marras0914/offline-triage-node/issues/11) — repeats are **linked, not suppressed**: a household’s second message is usually an escalation, so hiding it would be the dangerous choice. A database trigger, so every insert path inherits it
- [ ] [Backend utilities and a physical alarm](https://github.com/marras0914/offline-triage-node/issues/12) — the software alarm is done (terminal watcher and a screen page, both refusing to look calm when they cannot see the queue). **Nothing reaches anyone away from the node**, which is the part still missing
- [x] [Local MCP toolbelt](https://github.com/marras0914/offline-triage-node/issues/13) — six read-only tools a coordinator can query in plain language ([mcp/](mcp/)); off the intake path, and unable to write by database grant
- [x] [Agent eval](https://github.com/marras0914/offline-triage-node/issues/24) — 10 questions against a fixture queue ([eval/AGENT.md](eval/AGENT.md)). `llama3.1:8b`: 0 fabricated ids, 7/8 facts, 7/8 tool choice. It found a real defect on its first run — and a false pass in its own assertions

### Phase 4 — Physical Field Testing

*Simulate a total power and internet blackout to test the physical limits of the hardware.*

- [ ] [The blackout test](https://github.com/marras0914/offline-triage-node/issues/14) — unplug the upstream modem; local DNS and container comms must be unaffected
- [ ] [Power draw analysis](https://github.com/marras0914/offline-triage-node/issues/15) — measure idle vs. inference wattage and size the LiFePO4 pack for 72 hours
- [ ] [Mesh density testing](https://github.com/marras0914/offline-triage-node/issues/16) — daisy-chain outdoor APs and find the real range at which the portal still serves

---

The Edge Triage Node: Autonomous Offline Infrastructure
When disaster strikes, the centralized systems we rely on—macro-energy grids, cellular towers, and cloud servers—are often the first to fail. In the critical hours following an emergency, local communities lose the ability to coordinate rescues, distribute resources, and triage medical needs.

Drawing from enterprise-scale grid modernization and load-balancing principles, this project flips the traditional infrastructure model on its head. Instead of relying on a massive, vulnerable centralized system, we are pushing resilience and compute to the absolute edge.

The Convergence of Disciplines
The Edge Triage Node is a convergence of decentralized energy, open-source mesh networking, and autonomous AI. It takes the robust container orchestration typically reserved for hardened server environments and scales it down into a single, portable, battery-backed micro-server.

By leveraging hardware like a localized NUC paired with high-density mesh access points, the node broadcasts a resilient "walled garden" Wi-Fi network over a disaster zone. But it does not just act as a communication relay; it acts as an active, agentic dispatcher.

Agentic Edge Automation
When users connect to the emergency network, a captive portal captures their unstructured requests for help. Operating entirely offline, a locally hosted Large Language Model processes this raw panic, strips away the chaos, and categorizes the data into strict, actionable JSON schemas. Automated local workflows then instantly route these critical insights to offline databases and local medic dashboards.

Impact Over Output
This project is a commitment to building technology for the public good. It proves that enterprise-grade automation and cutting-edge AI do not need to be locked behind expensive cloud subscriptions or high-bandwidth connections. By open-sourcing this architecture, we provide a blueprint for autonomous, self-healing infrastructure that ensures when the cloud goes dark, local communities remain connected, organized, and empowered.