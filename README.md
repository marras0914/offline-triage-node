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