# Contributing to the Edge Triage Node

First off, thank you for considering contributing to the Edge Triage Node project. 

When centralized infrastructure fails, local communities rely on resilient, offline-first technology to coordinate aid and save lives. By contributing to this project, you are helping build autonomous, self-healing infrastructure for the public good.

Whether you are an AI researcher, a frontend developer, or a hardware tinkerer, your help is critical.

## 🛠️ Areas of Need

We are actively looking for contributions across four main domains:

1. **AI & Prompt Engineering:** Refining the local LLM system prompts (Llama 3/Phi-3) to ensure strict JSON output and zero hallucinations when parsing chaotic, unstructured emergency messages. **Prompt changes must be gated by the eval suite** — run `./eval/run-eval.sh` before and after, and put both results in the PR. The suite loads the prompt out of the deployed workflow, so there is no second copy to keep in sync. See [eval/README.md](eval/README.md); the bar is asymmetric on purpose, with 100% recall required on Critical. Changes to the MCP agent or its tools are gated by [eval/AGENT.md](eval/AGENT.md) instead, which allows no fabricated request ids at all.
2. **Workflow Automation (n8n):** Building out more robust edge cases for the n8n routing logic. How do we handle duplicate requests? How do we integrate LoRa mesh bridging via MQTT?
3. **Frontend / Captive Portal:** Keeping the Nginx HTML/JS portal incredibly lightweight but adding offline-cached mapping (e.g., OpenStreetMap tiles) or multilingual support.
4. **Hardware & Networking:** Field-testing the Docker stack on different mini-PCs, optimizing UniFi/MikroTik mesh configurations, and documenting battery/solar power draw.

## 💻 Development Setup

To start contributing, you will need a machine capable of running Docker and enough RAM to run a local 8B parameter model (16GB minimum recommended).

1. Fork the repository.
2. Clone your fork locally: `git clone https://github.com/YOUR-USERNAME/offline-triage-node.git`
3. Run `./install.sh`. It generates `.env`, boots the stack, applies the schema, pulls the model, imports the triage workflow, and smoke tests the whole intake path. It is safe to re-run after changes.
4. Edited the workflow in the n8n editor? Export it back over `n8n/workflows/sos-intake-triage.json` (keep the `id` field intact — that is what makes re-import update in place instead of duplicating).

*For detailed setup instructions, please see our [DEPLOYMENT.md](DEPLOYMENT.md).*

## 🔄 Pull Request Process

1. **Branching:** Create a new branch for your feature or bugfix (e.g., `feature/offline-maps` or `fix/n8n-routing-error`).
2. **Testing:** Because this is emergency infrastructure, code reliability is paramount. Run the suites covering what you touched, and put the results in the PR:

   | If you changed | Run |
   | --- | --- |
   | `install.sh` or `scripts/make-offline-bundle.sh` | `./test-install.sh` |
   | anything in `db/init/` | `./db/test-schema.sh` |
   | `html/index.html` | `node html/test-portal.mjs` |
   | the workflow prompt, or `DEFAULT_MODEL` | `./eval/run-eval.sh` — before **and** after, both results in the PR |
   | `mcp/server.mjs` or `mcp/agent.mjs` | `./eval/run-agent-eval.sh` |

   The first three need no network and no running stack; see [Verifying your clone](README.md#verifying-your-clone). Whatever else you change, do not break the core offline webhook pipeline.
3. **Documentation:** If you add a new service to the `docker-compose.yml` or change the network architecture, update the `ARCHITECTURE.md` file accordingly.
4. **Submission:** Open a PR against the `main` branch. Provide a clear summary of the problem you are solving and how you tested it locally.

## 🏕️ Field Testing & Bug Reports

You don't need to write code to contribute. If you deploy this stack on a NUC, a Raspberry Pi 5, or within a specific UniFi/hardware environment, we want to know how it performs. 

Please open an **Issue** to report:
* Unexpected power draw or hardware bottlenecks.
* Routing failures or LLM prompt hallucinations.
* Captive portal connection issues on specific mobile devices.

## 🤝 Code of Conduct

This project is built to help people in their most vulnerable moments, and our community reflects that mission. Be respectful, be patient with newcomers, and assume positive intent in all PR reviews and issue discussions.
