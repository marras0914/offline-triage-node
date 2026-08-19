# System Architecture

The edge node utilizes a completely isolated, localized stack running within a Docker network.

## 1. Network Layer (The Mesh & Walled Garden)
*   **Isolated VLAN:** The local router broadcasts an open `EMERGENCY-TEST` SSID assigned to a strict guest VLAN.
*   **Captive Portal:** The router hijacks DNS probes from connecting devices, forcing them to a local Nginx web server running on the NUC.
*   **Walled Garden:** The router's Pre-Authorization Access list allows unauthenticated traffic to reach **port 80 only** on the NUC's static IP. Ports 5678 (n8n) and 8080 (NocoDB) are operator and coordinator surfaces and stay off the guest VLAN — a survivor's phone never needs them, because Nginx proxies the intake webhook under its own origin.

## 2. Infrastructure Layer (Docker Compose)
All services are constrained within an internal Docker bridge network (`edge_network`).
*   **Nginx:** Serves the static HTML SOS form, and reverse-proxies `POST /api/sos` to the n8n production webhook. Keeping the form same-origin removes the CORS preflight a cross-origin JSON `fetch` would trigger, and means no node IP is baked into the HTML.
*   **Ollama:** Runs the local LLM (`llama3.1` or `phi3`). Not published to the host; reachable only over internal Docker DNS.
*   **Postgres:** Three databases on one server — `triage` (field data), `n8n_primary` (n8n's internal state, including its encrypted credential store), and `nocodb_meta` (NocoDB's own bookkeeping). Separated so a coordinator working in a spreadsheet UI is never one wrong click from n8n's internals.
*   **NocoDB:** A spreadsheet-like visual database client on port 8080. Attaches `triage` as a data source for coordinators to work the queue.
*   **n8n:** The orchestration engine linking the webhook, the AI, and the database.

## 3. The Data Flow (n8n Pipeline)

Workflow: `n8n/workflows/sos-intake-triage.json` — imported and activated by `install.sh`.

1.  **Intake:** The form `POST`s to `/api/sos` on port 80 → Nginx proxies to the n8n Webhook node at `/webhook/sos-intake`.
2.  **Normalize:** A Code node trims and length-caps the three fields, rejects an incomplete submission, and builds the Ollama request. `raw_message` is preserved verbatim from here on — a coordinator must always be able to read what the person actually typed.
3.  **AI Triage:** An HTTP node calls `http://ollama:11434/api/chat` with `format` set to a JSON Schema, which constrains decoding to the shape rather than just asking the model for JSON. Returns `severity` (Critical, Urgent, Standard), `category` (Medical, Structural, Supply), a one-sentence `summary`, and `people_affected`, at `temperature: 0`.
4.  **Validate:** A Code node parses the response, whitelists both enums against the schema's allowed values, and applies two deterministic backstops (below).
5.  **Store:** Inserted into `triage.requests`.
6.  **Respond:** The portal gets `{ status, id }` and shows the request number. Severity is deliberately *not* returned — the portal should neither reassure nor alarm.

## 4. Failure Behaviour

The design rule is that **nothing the model does may cost us a request.**

If Ollama is unreachable, times out, or returns an unusable payload, the HTTP node's error falls through to the validate step instead of aborting the run. The row is still written, with:

*   `needs_review = TRUE` and the failure recorded in `triage_error`,
*   `severity` defaulted to `Critical` and `category` to `Medical`,
*   `summary` falling back to the first 140 characters of the raw message.

Escalate on uncertainty: an unclassified request surfaces at the top of a human's queue rather than being dropped or quietly filed as Standard. The same defaults are set on the table itself, so any insert path that skips classification behaves identically.

## 5. Deterministic Backstops

Escalate-on-uncertainty assumes failure *looks* like uncertainty — a timeout, unparseable output, a bad enum. One failure mode breaks that assumption: the model can be confident and wrong. Intake is a public, unauthenticated endpoint, so the message body is attacker-controlled text that reaches the prompt, and a local model will follow instructions found there. Measured, not theorised: all three `inject-*` cases in the eval suite were downgraded to Standard while the model's own summary correctly described a child in a burning house.

Two checks in **Validate Triage** therefore sit outside the model's reach. Both are regex, not inference, so text in the message cannot argue with them.

*   **Severity floor.** High-precision Critical indicators — not breathing, unconscious, trapped, on fire, severe bleeding, drowning, and their Spanish equivalents — are matched against `raw_message`. The model may raise severity; it may never lower it below a keyword match. The list is kept deliberately narrow: over-escalation only costs noise in a queue, but a floor that fired on everything would flatten the queue and destroy the ordering it exists to provide.
*   **Injection flag.** Instruction-shaped text in a field that should only ever hold a report (`ignore ... instructions`, `SYSTEM:`, `set severity`) marks the classification untrustworthy — `needs_review`, severity to Critical — rather than wrong in a knowable direction. This is not only an attack: a forwarded message or a pasted form letter trips it.

The model sorts. The regex guarantees a floor. Prompt hardening (the report is fenced and declared to be data, not instructions) is defence in depth behind both, never the primary control.

