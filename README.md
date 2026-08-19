# Offline-First Edge Triage Node

This project is a self-hosted, offline-first disaster response computing node. It is designed to be deployed in environments where cellular and internet infrastructure has failed, providing a localized emergency mesh network, an automated SOS intake portal, and an AI-driven triage routing system.

## The Problem
When centralized infrastructure fails during a disaster, local communities lose the ability to coordinate rescues, request aid, and triage resources. 

## The Solution
A portable, battery-backed edge computing node that broadcasts a local Wi-Fi mesh. Users connect, are forced to a captive portal, and submit SOS requests. A local LLM processes the unstructured requests, categorizes them by severity, and routes them to offline databases and local medic dashboards.

## Status

Pre-field-test. The stack deploys and the intake pipeline runs end to end, but this has not yet been validated in a live incident. See the [roadmap board](https://github.com/users/marras0914/projects/2) for what is verified and what is not.

**This is not a substitute for emergency services.** Where any emergency number still answers, call it. This node is built for the hours when nothing answers — and its AI triage is a queue-ordering aid for human coordinators, never an authority on who gets help first. Requests the model cannot classify are escalated to Critical and flagged for a human rather than filed automatically.

## Minimum Hardware Requirements

*   **Compute (Mini-PC/NUC):** AMD Ryzen 7 8845HS (or Intel Core Ultra 7 155H) to provide sufficient iGPU compute for local AI inference.
*   **Memory:** Minimum 32GB Dual-Channel DDR5-5600 RAM (critical for LLM memory bandwidth).
*   **Storage:** 1TB Gen 4 NVMe SSD.
*   **Networking:** Weather-resistant mesh access points (e.g., UniFi U6 Mesh) and a ruggedized PoE switch.
*   **Power:** LiFePO4 battery pack coupled with a pure sine wave inverter.

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
- [ ] [Coordinator runbook](https://github.com/marras0914/offline-triage-node/issues/18) — the `needs_review` queue currently has no human assigned to watch it
- [ ] [Rate limiting](https://github.com/marras0914/offline-triage-node/issues/19) — `/api/sos` is unauthenticated by design, but uncapped

### Phase 2 — Network Isolation & Captive Portal

*Move off the standard LAN and prove the offline DNS hijacking and mobile UI work as intended.*

- [ ] [VLAN configuration](https://github.com/marras0914/offline-triage-node/issues/5) — isolated guest VLAN broadcasting the open `EMERGENCY-TEST` SSID
- [ ] [Walled garden](https://github.com/marras0914/offline-triage-node/issues/6) — pre-authorization access to the NUC on **port 80 only**; survivors never touch 5678 or 8080
- [ ] [Captive portal redirect](https://github.com/marras0914/offline-triage-node/issues/7) — a phone joins and the OS opens the form by itself
- [ ] [End-to-end mobile test](https://github.com/marras0914/offline-triage-node/issues/8) — a chaotic SOS from a handset arrives as a clean row in NocoDB

### Phase 3 — AI Hardening & Custom Tooling

*Prevent the local agent from hallucinating under stress, and extend the system's logic.*

- [ ] [Chaos testing](https://github.com/marras0914/offline-triage-node/issues/9) — a committed golden set of panicked, ambiguous messages, run as a regression suite rather than eyeballed
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