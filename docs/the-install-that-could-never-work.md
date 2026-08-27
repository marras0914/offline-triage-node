# Four checks that could never fire

A post-mortem from an offline-first disaster response node, about a class of bug that passes every test you have.

## The setup

The [Edge Triage Node](an-offline-triage-node.md) exists for the hours after the network fails: it broadcasts its own Wi-Fi, takes SOS submissions from phones, sorts them by severity with a local language model, and hands a coordinator a queue to work. Its defining constraint is that you cannot download anything at the moment you need it. So there is a bundle — a script runs on a machine that *has* a connection and stages every container image and the model itself onto a USB stick, about 12.7 GB. On the target machine, the installer finds the bundle and loads from it instead of reaching for the network.

That path was written, reviewed, documented, and — as the README said plainly — never actually run.

This week we ran it. It failed four different ways. Every one of the four was the same mistake.

## Bug 1: the archive that could not be unpacked

The restore piped a gzipped tarball through `gunzip` and into `tar`:

```bash
gunzip -c "$BUNDLE/ollama-models.tar.gz" \
  | docker compose exec -T ollama tar -xzf - -C /root/.ollama
```

`gunzip -c` decompresses. Then `tar -xzf` is asked to decompress again, and dies:

```
gzip: stdin: not in gzip format
```

The bundle built perfectly. Its contents were complete, its sizes were right, and it could never be restored by the only code that ever tried. Dropping the `z` is the entire fix.

## Bug 2: the model that was present and reported missing

With the archive restored, the installer checks the model arrived:

```bash
docker compose exec -T ollama ollama list | grep -q "^${TRIAGE_MODEL}[[:space:]]"
```

`TRIAGE_MODEL` comes from the workflow, where it is `llama3.1`. But `ollama list` prints tagged names, so the row reads:

```
llama3.1:latest    42182419e950    4.7 GB    2 days ago
```

`^llama3.1[[:space:]]` requires whitespace immediately after the name. What follows is a colon. The check never matched — not once, on any machine, under any circumstances.

It had two consequences, and the quiet one had been costing time for weeks. The same check gates an "already present, nothing to fetch" fast path, so every install re-fetched a 4.7 GB model that was already sitting there. The loud one only appeared offline: the check also *verifies* the restore, so a bundle that had restored flawlessly aborted the install with

> the bundle was restored but 'llama3.1' is not in it. Rebuild the bundle

telling the operator to discard a perfectly good 12.7 GB bundle and rebuild it from a connection they do not have.

The fix compares the first column exactly, against both the bare name and the `:latest` spelling.

## Bug 3: healthy is not ready

Past that, the stack came up, the schema applied, the workflows imported. Then step 7 restarts n8n so the production webhook registers, and waits for it:

```bash
docker compose restart n8n
for _ in $(seq 1 30); do
  if docker compose exec -T n8n wget -q -O- http://localhost:5678/healthz; then break; fi
  sleep 2
done
```

Step 8 then posts a test SOS through the whole pipeline. It got:

```
Cannot POST /webhook/sos-intake
```

`/healthz` answers as soon as the process is listening. Webhook registration happens later. The wait was real, the endpoint was real, and it measured the wrong thing — so the smoke test fired into the gap and reported a working node as broken. The identical POST, sent by hand a few minutes later, returned `200` and a stored, correctly classified row.

## Bug 4: success by default

This is the one that should worry you most, and it is one character long.

The failure branch printed a diagnosis. Then the script carried on, printed

```
========================================================
  Deployment complete
========================================================
  Portal:    http://127.0.0.1/           (survivors, port 80 only)
  ...
  Start the queue alarm now:  ./scripts/watch-queue.sh
```

and exited `0`.

So the default experience of a *correctly installed* node was a spurious failure that announced itself as a success. On a scrolling console, in a field, the operator sees a green banner and a list of URLs, hands the box to a coordinator, and the failure is twenty lines above the fold.

## The shape of it

Four bugs, one mistake repeated: **every one was a check standing in for something it could not measure directly.**

| The check | What it stood for | Why it could not work |
| --- | --- | --- |
| `tar -xzf` on a decompressed stream | "unpack the archive" | tar was asked to do a job already done |
| `grep "^name[[:space:]]"` | "is the model present" | the real output is `name:tag`, never `name ` |
| `/healthz` returns 200 | "the webhook is registered" | health precedes readiness |
| the script reached the end | "the deployment worked" | reaching the end proves only that nothing crashed |

None of these are exotic. Each is the obvious thing to write. And each is a proxy that can be true while the condition it represents is false — which is exactly the bug you cannot find by reading, because reading is how it got there. A proxy check is invisible in review precisely because it looks like the thing it replaces.

It is worth being specific about why the test suite was no defence, because there was a real one: 31 schema assertions, 17 portal tests, a 53-case triage eval with a hard gate on recall of critical cases. All of it tested *components*. Every one of these four bugs lived in the seams between components, in the glue script nobody thought of as code. The proxies were load-bearing and untested, and the only thing that could have caught them was running the real path once.

Nothing did, for months, because running it means staging 12.7 GB and installing from scratch. The cost of the test is exactly why the test never happened, and exactly why four bugs accumulated undisturbed. If you have a path whose test is expensive, assume it is broken. It probably is, and you will find out at the worst available moment — which for this project means during a blackout, holding a USB stick, with someone waiting.

## What changed, beyond the four fixes

Fixing the bugs was the easy half. The useful half was making this class of thing fail loudly next time.

**Tests that run the shipped code, not a copy of it.** The suite `sed`-extracts the actual functions out of `install.sh` and executes them against fixtures — real `ollama list` output for the presence check, a stubbed `curl` for the retry loop, a real fixture archive built the way the bundle builder builds one. A test holding its own copy of the logic passes while the shipped code rots. Run against the pre-fix installer, this suite fails exactly twice, once per bug; against the fixed one it passes 21 times.

**The builder verifies its own output.** It now reads both archives back before writing the manifest, confirming every pinned image is really inside and that the model's manifest exists under the exact name the installer will look it up by. A bundle that cannot be restored now fails on the machine that still has a connection to fix it. That is the whole trade: 90 seconds there, or a dead node in a blackout.

**The smoke test became its own readiness gate.** Rather than guessing at readiness with `/healthz` and posting once, it retries the real POST until the pipeline answers. A successful submission *is* the proof of readiness, with no proxy in between. The loop only continues while failing, so at most one row is ever stored, and it is deleted afterwards.

**The exit code tells the truth.** A smoke test that never succeeds now prints an explicit "deployment INCOMPLETE" banner, says not to hand the node to a coordinator, and exits non-zero. A missing `curl` is reported as unproven rather than quietly counted as either.

## Did it hold?

The installer was re-run against the same bundle, on the same machine, end to end:

```
[5/8] Pulling the local model (llama3.1)...
  Already present; nothing to fetch.

[7/8] Restarting n8n to register the production webhook...
[8/8] Smoke testing the full intake path...
  Webhook not registered yet; waiting for it...
  Portal -> n8n -> Ollama -> Postgres: OK  {"status":"received","id":"2"}
  AI triage classified it cleanly using llama3.1.
  Test row removed.
```

Two things in that output are the point. `Already present; nothing to fetch` is bug 2 fixed in the direction nobody had ever seen work — the fast path firing for the first time. And `Webhook not registered yet; waiting for it...` means the race in bug 3 **happened again** on this run, and the retry absorbed it. The bug is still there, in the sense that n8n still reports healthy before it is ready. It just cannot cause a false failure any more.

The air-gapped install now runs start to finish, restores a 4.5 GB model from removable media, classifies a live submission with it, cleans up after itself, and exits truthfully.

## What is still not true

This is emergency infrastructure that has never been in an emergency. The node has not been validated on deployed hardware in a field, or against a real handset. Captive portal detection on iOS and Android, VLAN and mesh behaviour, and power draw over 72 hours are all still ahead, and no amount of further desk work substitutes for them.

Which is the same lesson as the four bugs, pointed forward instead of back. Everything above was true, reviewed, and wrong, right up until someone ran it.

**Repository:** <https://github.com/marras0914/offline-triage-node>
