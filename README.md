# Offline-First Edge Triage Node

This project is a self-hosted, offline-first disaster response computing node. It is designed to be deployed in environments where cellular and internet infrastructure has failed, providing a localized emergency mesh network, an automated SOS intake portal, and an AI-driven triage routing system.

## The Problem
When centralized infrastructure fails during a disaster, local communities lose the ability to coordinate rescues, request aid, and triage resources. 

## The Solution
A portable, battery-backed edge computing node that broadcasts a local Wi-Fi mesh. Users connect, are forced to a captive portal, and submit SOS requests. A local LLM processes the unstructured requests, categorizes them by severity, and routes them to offline databases and local medic dashboards.

## Status

Pre-field-test. The stack deploys and the intake pipeline runs end to end, but this has not yet been validated in a live incident. See the [roadmap board](https://github.com/users/marras0914/projects/2) for what is verified and what is not.

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
| Prepositioned NUC, 32GB, iGPU | `llama3.1` 8B | The full design |
| Any modern laptop, 16GB+, no GPU | `llama3.1` 8B on CPU | Full triage, ~13s per request (measured) |
| Older laptop, 8GB | `llama3.2:3b` | Triage with 9/13 rather than 13/13 on the Urgent tier |
| 4GB, a Raspberry Pi, or no model at all | none | **Intake and dashboard, no AI** — see below |

Storage is not the constraint the spec implies: images and an 8B model come to roughly 13GB, so any disk with 20GB free will do.

### Measured on a laptop, CPU only

Not estimates. This project's own [eval suite](eval/) run on an MSI Commercial 14 (i7-13700H, 32GB) under Docker Desktop on Windows, which gives Ollama **no GPU access at all** — so this is close to the realistic worst case for a machine of that class.

| Model | RAM | p50 | p90 | Worst | Queue ordering |
| --- | --- | --- | --- | --- | --- |
| `llama3.2:1b` | ~2GB | 4.8s | 7.7s | 15s | **Worthless** — every tier collapses to Critical |
| `llama3.2:3b` | ~4GB | 6.7s | 10.3s | 55s | Good — 9/13 Urgent correct, 92.5% category |
| `llama3.1:8b` | ~8GB | 13.4s | 19.5s | 136s | Best — 13/13 Urgent correct, 98.1% category |

**Do not go below 3B.** 1B runs anywhere and is not worth running: it satisfies the JSON schema contract perfectly and fails at the actual job, marking everything Critical. A queue where every row is the top priority is a queue you have to read end to end, which is the thing this system exists to avoid.

**8B is comfortable on a laptop CPU.** 13s median for a form submission is unnoticeable to someone typing, and the request is stored regardless — nobody's request depends on inference finishing. The nginx proxy allows 300s and the n8n node 180s, so even the 136s worst case fits.

Throughput is the real limit, not latency. Ollama serialises requests, so at ~13s each a single node handles roughly four or five submissions a minute before a queue forms; the concurrency caps in `nginx/default.conf` shed load rather than letting fifty people each wait behind it. If that ceiling matters for your population, that is the argument for the prepositioned build's iGPU — not the latency.

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

1.  **You cannot download anything during a blackout** ([#21](https://github.com/marras0914/offline-triage-node/issues/21)). `install.sh` currently pulls five images and a multi-GB model from the internet. Until an offline bundle exists, the node has to be built *before* it is needed — which quietly means the blueprint only helps people who predicted the emergency.
2.  **A laptop hotspot still cannot serve a captive portal** ([#22](https://github.com/marras0914/offline-triage-node/issues/22)). The *router* half of this is now solved: `docker compose --profile captive-dns up -d` answers every hostname with the node, so a plain consumer router works — set its DHCP-advertised DNS to the node and detection fires. What remains is the laptop's own hotspot, where binding port 80 and controlling DNS both need privileges the OS does not hand out, and where client limits are typically around eight devices.

## Documentation

*   **[DEPLOYMENT.md](DEPLOYMENT.md)** — installing, including with no internet
*   **[OPERATIONS.md](OPERATIONS.md)** — running it: who watches the queue, the four checks, backups, handover
*   **[ARCHITECTURE.md](ARCHITECTURE.md)** — the stack, the data flow, and the deterministic safety backstops
*   **[eval/README.md](eval/README.md)** — the triage regression suite and what it does and does not prove
*   **[CONTRIBUTING.md](CONTRIBUTING.md)** — where help is needed

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

- [ ] [Pin all image tags](https://github.com/marras0914/offline-triage-node/issues/17) — a rebuild mid-incident must not pull a release that changes node behaviour
- [x] [Coordinator runbook](https://github.com/marras0914/offline-triage-node/issues/18) — [OPERATIONS.md](OPERATIONS.md), plus the `review_pile` / `queue_health` views and an audit trail so "nobody looked" is visible rather than silent
- [ ] [Rate limiting](https://github.com/marras0914/offline-triage-node/issues/19) — `/api/sos` is unauthenticated by design, but uncapped

### Phase 2 — Network Isolation & Captive Portal

*Move off the standard LAN and prove the offline DNS hijacking and mobile UI work as intended.*

- [ ] [VLAN configuration](https://github.com/marras0914/offline-triage-node/issues/5) — isolated guest VLAN broadcasting the open `EMERGENCY-TEST` SSID
- [ ] [Walled garden](https://github.com/marras0914/offline-triage-node/issues/6) — pre-authorization access to the NUC on **port 80 only**; survivors never touch 5678 or 8080
- [ ] [Captive portal redirect](https://github.com/marras0914/offline-triage-node/issues/7) — a phone joins and the OS opens the form by itself
- [ ] [End-to-end mobile test](https://github.com/marras0914/offline-triage-node/issues/8) — a chaotic SOS from a handset arrives as a clean row in NocoDB

### Phase 3 — AI Hardening & Custom Tooling

*Prevent the local agent from hallucinating under stress, and extend the system's logic.*

- [x] [Chaos testing](https://github.com/marras0914/offline-triage-node/issues/9) — 42-case golden set and a regression harness that loads the deployed prompt, so a prompt edit is tested by definition ([eval/](eval/)). Baselined; still to re-run at 8B
- [ ] [Prompt injection can bury a Critical request](https://github.com/marras0914/offline-triage-node/issues/20) — confirmed and mitigated by a deterministic severity floor; the eval `inject-*` cases are the regression test
- [ ] [Model invents injuries from noise](https://github.com/marras0914/offline-triage-node/issues/10) — confirmed defect: pure gibberish produced *"Unconscious person needs medical attention."* Escalating noise to Critical is correct; fabricating a casualty is not
- [ ] [Deduplicate rapid-fire requests](https://github.com/marras0914/offline-triage-node/issues/11) — the same household will submit several times
- [ ] [Backend utilities](https://github.com/marras0914/offline-triage-node/issues/12) — sanitization, and physical triggers so a coordinator away from the screen still gets told
- [ ] [Local MCP toolbelt](https://github.com/marras0914/offline-triage-node/issues/13) — let the agent check whether a reporter has already asked for aid, without putting intake on the critical path

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