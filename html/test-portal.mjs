#!/usr/bin/env node
//
// Tests the portal's offline behaviour without a browser.
//
//   node html/test-portal.mjs
//
// "The phone holds the request until the node confirms it" is a safety claim made
// in the README and in OPERATIONS.md, and it was previously untested. The failure
// modes here are all silent — a request quietly dropped, or a page that says
// "received" when nothing was stored — so they need pinning rather than
// eyeballing.
//
// Stubs the DOM, fetch, localStorage and timers, then runs the real script out of
// index.html. No dependencies, no jsdom: the point is that this runs anywhere the
// rest of the tooling does.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(HERE, 'index.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

const results = [];
const check = (label, ok) => { results.push({ label, ok }); };

// ---------------------------------------------------------------- environment
function makeEnv({ fetchImpl, storage = {} }) {
  const listeners = {};
  const els = {};
  const mk = (id) => ({
    id, value: '', textContent: '', hidden: false, disabled: false,
    style: {}, _handlers: {},
    addEventListener(ev, fn) { this._handlers[ev] = fn; },
    querySelector: () => els.submit,
  });
  for (const id of ['sosForm', 'statusMessage', 'retryNow', 'name', 'location', 'message']) els[id] = mk(id);
  els.submit = mk('submit');
  els.sosForm.querySelector = () => els.submit;
  els.sosForm.reset = function () { els.name.value = els.location.value = els.message.value = ''; };

  // Virtual clock, so a 20-minute give-up window is testable in milliseconds.
  let now = 0;
  const timers = [];
  const env = {
    now: () => now,
    els,
    document: {
      getElementById: (id) => els[id],
      addEventListener: (ev, fn) => { listeners[ev] = fn; },
      get visibilityState() { return env.visibility || 'visible'; },
    },
    localStorage: {
      getItem: (k) => (k in storage ? storage[k] : null),
      setItem: (k, v) => { storage[k] = String(v); },
      removeItem: (k) => { delete storage[k]; },
    },
    storage,
    fire: (ev) => listeners[ev] && listeners[ev](),
    setTimeout: (fn, ms) => { const t = { fn, at: now + (ms || 0), id: timers.length + 1 }; timers.push(t); return t.id; },
    clearTimeout: (id) => { const i = timers.findIndex((t) => t.id === id); if (i >= 0) timers.splice(i, 1); },
    // Advances the clock, running due timers in order. Awaits between each so
    // the async send() settles before the next one is scheduled.
    async advance(ms) {
      const target = now + ms;
      for (let guard = 0; guard < 500; guard++) {
        const due = timers.filter((t) => t.at <= target).sort((a, b) => a.at - b.at)[0];
        if (!due) break;
        timers.splice(timers.indexOf(due), 1);
        now = due.at;
        await due.fn();
        await new Promise((r) => setImmediate(r));
      }
      now = target;
    },
    fetch: fetchImpl,
  };
  return env;
}

async function run(env) {
  const fn = new Function(
    'document', 'localStorage', 'fetch', 'setTimeout', 'clearTimeout', 'Date',
    script
  );
  const FakeDate = class extends Date { static now() { return env.now(); } };
  fn(env.document, env.localStorage, env.fetch, env.setTimeout, env.clearTimeout, FakeDate);
  await new Promise((r) => setImmediate(r));
}

const ok = (body, status = 200) => async () => ({
  status, ok: status < 400, json: async () => body,
});
const netFail = () => async () => { throw new Error('network down'); };

function submit(env, msg = 'roof collapsed, person trapped') {
  env.els.name.value = 'Test Family';
  env.els.location.value = '4th and Main';
  env.els.message.value = msg;
  return env.els.sosForm._handlers.submit({ preventDefault() {} });
}

// ============================================================ tests
{
  // A successful send reports the id and keeps nothing on the phone.
  const env = makeEnv({ fetchImpl: ok({ status: 'received', id: '7' }) });
  await run(env);
  await submit(env);
  await new Promise((r) => setImmediate(r));
  check('a stored request reports its id', /#7/.test(env.els.statusMessage.textContent));
  check('nothing is left pending after success', !env.storage['triage.pending']);
}

{
  // The bug that mattered most: an errored n8n execution answers 200 with an
  // empty body, and the portal must not read that as success.
  const env = makeEnv({ fetchImpl: ok({}) });
  await run(env);
  await submit(env);
  await new Promise((r) => setImmediate(r));
  check('HTTP 200 with an empty body is NOT reported as sent',
    /NOT SENT/.test(env.els.statusMessage.textContent));
}

{
  // Network loss: the request must be held, and never described as sent.
  const env = makeEnv({ fetchImpl: netFail() });
  await run(env);
  await submit(env);
  await new Promise((r) => setImmediate(r));
  check('a dropped network holds the request on the phone', !!env.storage['triage.pending']);
  check('and says NOT SENT YET rather than sent',
    /NOT SENT YET/.test(env.els.statusMessage.textContent));
  check('the held payload is what the person typed',
    JSON.parse(env.storage['triage.pending']).payload.message === 'roof collapsed, person trapped');
}

{
  // Comes back into range: the retry must deliver it without the person acting.
  let calls = 0;
  const env = makeEnv({
    fetchImpl: async () => {
      calls++;
      if (calls <= 2) throw new Error('still out of range');
      return { status: 200, ok: true, json: async () => ({ status: 'received', id: '12' }) };
    },
  });
  await run(env);
  await submit(env);
  await env.advance(60000);
  check('an automatic retry delivers it once back in range', /#12/.test(env.els.statusMessage.textContent));
  check('and clears it from the phone', !env.storage['triage.pending']);
}

{
  // Backoff: attempts must thin out rather than hammer at a fixed interval.
  let calls = 0;
  const env = makeEnv({ fetchImpl: async () => { calls++; throw new Error('down'); } });
  await run(env);
  await submit(env);
  await env.advance(20 * 60 * 1000);
  check('backoff keeps 20 minutes of retries under 30 attempts', calls > 5 && calls < 30);
  check('a request that never sends is still on the phone', !!env.storage['triage.pending']);
  check('and the person is told it was not sent, not that it failed silently',
    /STILL NOT SENT|NOT SENT/.test(env.els.statusMessage.textContent));
  check('the manual retry button is offered once retrying stops', env.els.retryNow.hidden === false);
}

{
  // A 400 is a refusal on content. Resending identical content would only be
  // refused again, so it must not be retried or held.
  const env = makeEnv({ fetchImpl: ok({ status: 'rejected', message: 'Please describe what you need.' }, 400) });
  await run(env);
  await submit(env, '');
  await new Promise((r) => setImmediate(r));
  check('a 400 is not retried', !env.storage['triage.pending']);
  check('and the server reason is shown to the person',
    /Please describe what you need/.test(env.els.statusMessage.textContent));
}

{
  // A rate-limit shed is retryable, and must read as "wait", not "broken".
  const env = makeEnv({ fetchImpl: ok({ status: 'rejected', message: 'Too many requests from this device.' }, 429) });
  await run(env);
  await submit(env);
  await new Promise((r) => setImmediate(r));
  check('a 429 is held and retried', !!env.storage['triage.pending']);
}

{
  // An identical resubmission inside ten minutes is recorded against the request
  // already queued. Saying "we already have this" beats implying a second one.
  const env = makeEnv({ fetchImpl: ok({ status: 'received', id: '3', already_logged: true }) });
  await run(env);
  await submit(env);
  await new Promise((r) => setImmediate(r));
  check('a duplicate says the request is already in the queue',
    /already have this request/i.test(env.els.statusMessage.textContent));
}

{
  // A payload left by an earlier visit must be picked up on load.
  const env = makeEnv({
    fetchImpl: ok({ status: 'received', id: '99' }),
    storage: { 'triage.pending': JSON.stringify({ payload: { name: 'A', location: 'B', message: 'C' }, at: 0 }) },
  });
  await run(env);
  await env.advance(30000);
  check('a request held across a reload is resumed and sent', /#99/.test(env.els.statusMessage.textContent));
}

// ============================================================ report
console.log('');
for (const r of results) console.log(`  ${r.ok ? 'PASS' : 'FAIL'}  ${r.label}`);
const failed = results.filter((r) => !r.ok).length;
console.log(`\n  ${results.length - failed} passed, ${failed} failed\n`);
process.exit(failed ? 1 : 0);
