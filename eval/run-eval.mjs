#!/usr/bin/env node
//
// Triage regression harness.
//
// The point of this script is that it does NOT contain a copy of the prompt. It
// loads the deployed workflow, pulls out the Normalize Intake node's code, and
// runs that code to build each Ollama request — the same function that runs in
// production. Edit the prompt or the schema in the workflow and this harness
// tests the edit, with no second place to keep in sync.
//
// Usage (inside the n8n container, where node and Ollama's DNS both exist):
//   docker compose exec -T n8n node /eval/run-eval.mjs
//
// Or from a host that has node and a reachable Ollama:
//   OLLAMA_URL=http://localhost:11434 node eval/run-eval.mjs --model llama3.2:1b
//
// Flags:
//   --model <name>   override the workflow's DEFAULT_MODEL for this run
//   --tag <prefix>   only run cases whose id starts with this prefix
//   --limit <n>      stop after n cases
//   --json <path>    write full results as JSON
//   --quiet          summary only

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------- pass bar
//
// Critical recall is the metric that decides whether this is fit to deploy. A
// missed Critical is a person who does not get help; an over-escalation is only
// noise in a coordinator's queue. They are not comparable errors and the bar
// does not treat them as such.
// Severity exact-match is NOT gated, on purpose. It counts Urgent-read-as-Critical
// the same as Urgent-read-as-Standard, and those are not the same event: one is
// noise in a queue, the other is someone waiting behind blankets. Gating it would
// punish the safe error as hard as the dangerous one.
//
// Split instead. Under-escalation — anything assigned a *less* severe level than
// it deserves — is gated at zero. Over-escalation is gated too, but loosely and
// for a different reason: a classifier that answered "Critical" to everything
// would score perfect recall and zero under-escalation while making the queue
// useless. The over bar is what keeps the tiers meaningful.
//
// The 25% figure is provisional and should be reset from field data.
const BAR = {
  schemaViolations: 0,
  criticalRecall: 1.0,
  underEscalations: 0,
  overEscalationRate: 0.25,
  categoryAccuracy: 0.8,
  fabrications: 0,
};

const args = process.argv.slice(2);
const flag = (name, fallback = null) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const has = (name) => args.includes(`--${name}`);

const OLLAMA_URL = process.env.OLLAMA_URL || 'http://ollama:11434';
const WORKFLOW = flag('workflow', process.env.WORKFLOW_FILE || '/workflows/sos-intake-triage.json');
const GOLDEN = flag('golden', join(HERE, 'golden-set.jsonl'));
const quiet = has('quiet');

// ------------------------------------------------- load the deployed workflow
function loadWorkflow(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    // Fall back to the repo-relative copy so the harness also runs from a
    // checkout, not just from inside the container.
    return JSON.parse(readFileSync(join(HERE, '..', 'n8n', 'workflows', 'sos-intake-triage.json'), 'utf8'));
  }
}

function codeNode(workflow, name, ...params) {
  const node = workflow.nodes.find((n) => n.name === name);
  if (!node?.parameters?.jsCode) throw new Error(`Code node "${name}" not found in the workflow`);
  // A Code node body is a function body returning { json: ... }. Nothing else
  // from the n8n runtime is used, deliberately: n8n 2.x denies Code nodes access
  // to $env and throws on contact.
  return new Function(...params, node.parameters.jsCode);
}

const workflow = loadWorkflow(WORKFLOW);
const normalize = codeNode(workflow, 'Normalize Intake', '$input');
// Both Code nodes are run, not just the first. Validate Triage carries the
// deterministic severity floor and the injection check, so scoring the model's
// raw answer alone would miss the very safeguards that decide what reaches a
// coordinator. What this harness measures is what lands in Postgres.
const validate = codeNode(workflow, 'Validate Triage', '$', '$input');

// Validate Triage reads the intake back via $('Normalize Intake').first().json.
const nodeRef = (intakeJson) => (name) => {
  if (name !== 'Normalize Intake') throw new Error(`unexpected node reference: ${name}`);
  return { first: () => ({ json: intakeJson }), item: { json: intakeJson } };
};

const cases = readFileSync(GOLDEN, 'utf8')
  .split('\n')
  .map((l) => l.trim())
  .filter((l) => l && !l.startsWith('//'))
  .map((l) => JSON.parse(l))
  .filter((c) => {
    const tag = flag('tag');
    return !tag || c.id.startsWith(tag);
  })
  .slice(0, Number(flag('limit', Infinity)));

if (!cases.length) {
  console.error('No cases selected.');
  process.exit(2);
}

// ---------------------------------------------------------------- fabrication
//
// Applied only to cases marked no_fabrication (noise input). For real messages a
// paraphrase is expected and this check would false-positive constantly.
//
// Framing words the model may legitimately add are ignored; what we are hunting
// is a specific claim — a diagnosis, an injury, a count — with no basis in the
// input. "Unconscious person needs medical attention" from pure noise trips on
// "unconscious", which is exactly the failure this catches.
const FRAMING = new Set([
  'need', 'needs', 'needed', 'needing', 'help', 'helping', 'assistance', 'request',
  'requests', 'requested', 'requesting', 'require', 'requires', 'required',
  'person', 'persons', 'people', 'individual', 'someone', 'unknown', 'unclear',
  'unspecified', 'given', 'provided', 'information', 'details', 'detail',
  'reported', 'reporting', 'report', 'reports', 'location', 'immediate',
  'immediately', 'urgent', 'urgently', 'critical', 'standard', 'situation',
  'emergency', 'emergencies', 'assist', 'support', 'possible', 'possibly',
  'appears', 'seems', 'with', 'from', 'that', 'this', 'their', 'they', 'have',
  'has', 'been', 'about', 'into', 'unable', 'cannot', 'requesting',
]);

function fabricatedTerms(summary, sourceText) {
  const src = new Set((sourceText.toLowerCase().match(/[a-z]{3,}/g) || []));
  const stems = [...src].map((w) => w.slice(0, 4));
  const words = (String(summary || '').toLowerCase().match(/[a-z]{4,}/g) || []);
  return words.filter((w) => {
    if (FRAMING.has(w)) return false;
    if (src.has(w)) return false;
    // Tolerate inflection: "collapsed" against "collapse".
    return !stems.some((s) => w.startsWith(s));
  });
}

// ---------------------------------------------------------------------- run
const SEVERITIES = ['Critical', 'Urgent', 'Standard'];
const CATEGORIES = ['Medical', 'Structural', 'Supply'];
const results = [];
const modelOverride = flag('model');

if (!quiet) {
  console.log(`workflow : ${WORKFLOW}`);
  console.log(`ollama   : ${OLLAMA_URL}`);
  console.log(`cases    : ${cases.length}\n`);
}

for (const testCase of cases) {
  const built = normalize({
    item: { json: { body: { name: testCase.name || 'Eval Case', location: testCase.location || 'Eval', message: testCase.message } } },
  });
  const payload = { ...built.json.ollama_payload };
  if (modelOverride) payload.model = modelOverride;

  const record = { id: testCase.id, model: payload.model, expect: testCase.expect, problems: [] };
  const started = Date.now();

  try {
    let httpOut;
    try {
      const response = await fetch(`${OLLAMA_URL}/api/chat`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(180000),
      });
      httpOut = await response.json();
    } catch (networkError) {
      // Shape matches what the HTTP node hands downstream when it fails, so the
      // fail-safe path gets exercised rather than skipped.
      httpOut = { error: String(networkError.message || networkError) };
    }

    // --- schema: a contract about the MODEL's own output
    try {
      const modelOut = JSON.parse(httpOut.message.content);
      record.modelOut = modelOut;
      if (!SEVERITIES.includes(modelOut.severity)) record.problems.push(`schema: severity=${JSON.stringify(modelOut.severity)}`);
      if (!CATEGORIES.includes(modelOut.category)) record.problems.push(`schema: category=${JSON.stringify(modelOut.category)}`);
      if (typeof modelOut.summary !== 'string') record.problems.push('schema: summary not a string');
      if (!Number.isInteger(modelOut.people_affected)) record.problems.push('schema: people_affected not an integer');
    } catch (parseError) {
      record.problems.push(`schema: ${httpOut.error ? `no output (${String(httpOut.error).slice(0, 60)})` : 'model output unparseable'}`);
    }
    record.schemaValid = record.problems.length === 0;

    // --- labels: scored on the PIPELINE's output, after the floor and the
    //     injection check have had their say. This is what a coordinator sees.
    const out = validate(nodeRef(built.json), { item: { json: httpOut } }).json;
    record.got = out;
    record.needsReview = out.needs_review;
    record.triageError = out.triage_error;
    record.floorApplied = /severity floor applied/.test(out.triage_error || '');
    record.injectionFlagged = /instruction injection/.test(out.triage_error || '');

    const sevOk = testCase.expect.severity_ok || [testCase.expect.severity];
    const catOk = testCase.expect.category_ok || [testCase.expect.category];
    record.severityMatch = sevOk.includes(out.severity);
    record.categoryMatch = catOk.includes(out.category);

    if (testCase.expect.people !== undefined) {
      const peopleOk = testCase.expect.people_ok || [testCase.expect.people];
      record.peopleMatch = peopleOk.includes(out.people_affected);
    }

    // --- fabrication, measured at two levels
    //
    // Gated: what reaches a coordinator. Ungated but reported: what the model
    // itself produced, so a pipeline safeguard cannot be mistaken for the model
    // having improved.
    if (testCase.expect.no_fabrication) {
      const invented = fabricatedTerms(out.summary, testCase.message);
      record.fabricated = invented;
      if (invented.length) record.problems.push(`fabricated: ${invented.join(', ')}`);

      if (record.modelOut) {
        record.modelFabricated = fabricatedTerms(record.modelOut.summary, testCase.message);
      }
    }
  } catch (error) {
    record.error = String(error.message || error).slice(0, 200);
    record.schemaValid = false;
    record.severityMatch = false;
    record.categoryMatch = false;
    record.problems.push(`request: ${record.error}`);
  }

  record.ms = Date.now() - started;
  results.push(record);

  if (!quiet) {
    const mark = record.problems.length ? 'FAIL' : (record.severityMatch && record.categoryMatch ? 'ok  ' : 'MISS');
    const got = record.got ? `${record.got.severity}/${record.got.category} n=${record.got.people_affected}` : '(no result)';
    const want = `${testCase.expect.severity}/${testCase.expect.category}`;
    console.log(
      `${mark} ${testCase.id.padEnd(12)} got ${got.padEnd(26)} want ${want.padEnd(20)} ${String(record.ms).padStart(6)}ms` +
      (record.problems.length ? `\n       ${record.problems.join('; ')}` : '') +
      (record.got && !record.problems.length ? `\n       "${record.got.summary}"` : '')
    );
  }
}

// ------------------------------------------------------------------ scoring
const n = results.length;
const schemaViolations = results.filter((r) => !r.schemaValid).length;
const fabrications = results.filter((r) => r.fabricated?.length).length;
const severityAccuracy = results.filter((r) => r.severityMatch).length / n;
const categoryAccuracy = results.filter((r) => r.categoryMatch).length / n;

// Respects severity_ok, same as the under/over split below. Without that these
// two metrics disagree: a noise case whose label explicitly accepts Urgent was
// being reported as a missed Critical while not counting as under-escalated.
const expectedCritical = results.filter((r) => r.expect.severity === 'Critical');
const missedCritical = expectedCritical.filter(
  (r) => !(r.expect.severity_ok || [r.expect.severity]).includes(r.got?.severity),
);
const criticalRecall = expectedCritical.length ? 1 - missedCritical.length / expectedCritical.length : 1;

// Direction of error, which is the whole point. A case landing on anything in its
// severity_ok list is neither: that list exists because the rubric itself is
// ambiguous there, and scoring ambiguity as model error would be dishonest.
const RANK = { Critical: 0, Urgent: 1, Standard: 2 };
const direction = (r) => {
  const sevOk = r.expect.severity_ok || [r.expect.severity];
  if (!r.got || sevOk.includes(r.got.severity)) return 'ok';
  const got = RANK[r.got.severity];
  if (got === undefined) return 'invalid';
  return got > RANK[r.expect.severity] ? 'under' : 'over';
};
const underEscalated = results.filter((r) => direction(r) === 'under');
const overEscalated = results.filter((r) => direction(r) === 'over');
const overEscalationRate = overEscalated.length / n;

const peopleChecked = results.filter((r) => r.peopleMatch !== undefined);
const peopleAccuracy = peopleChecked.length
  ? peopleChecked.filter((r) => r.peopleMatch).length / peopleChecked.length
  : null;

const pct = (x) => `${(x * 100).toFixed(1)}%`;
const verdict = (name, value, bar, cmp = (v, b) => v >= b) =>
  `${cmp(value, bar) ? 'PASS' : 'FAIL'}  ${name}`;

console.log('\n' + '='.repeat(64));
console.log(`  Triage eval  ${results[0]?.model || 'unknown model'}  n=${n}`);
console.log('='.repeat(64));
console.log(`  ${verdict('schema violations', schemaViolations, BAR.schemaViolations, (v, b) => v <= b)}   ${schemaViolations} (bar ${BAR.schemaViolations})`);
console.log(`  ${verdict('critical recall  ', criticalRecall, BAR.criticalRecall)}   ${pct(criticalRecall)} (bar ${pct(BAR.criticalRecall)}) over ${expectedCritical.length} cases`);
console.log(`  ${verdict('under-escalated  ', underEscalated.length, BAR.underEscalations, (v, b) => v <= b)}   ${underEscalated.length} (bar ${BAR.underEscalations}) — assigned a LESS severe level than deserved`);
console.log(`  ${verdict('over-escalation   ', overEscalationRate, BAR.overEscalationRate, (v, b) => v <= b)}  ${pct(overEscalationRate)} (bar ${pct(BAR.overEscalationRate)}) — keeps the tiers meaningful`);
console.log(`  ${verdict('fabrications     ', fabrications, BAR.fabrications, (v, b) => v <= b)}   ${fabrications} (bar ${BAR.fabrications}) — reaching a coordinator`);
console.log(`  ${verdict('category accuracy', categoryAccuracy, BAR.categoryAccuracy)}   ${pct(categoryAccuracy)} (bar ${pct(BAR.categoryAccuracy)})`);
console.log(`        severity exact       ${pct(severityAccuracy)} (not gated: conflates the safe error with the dangerous one)`);
if (peopleAccuracy !== null) {
  console.log(`        people_affected      ${pct(peopleAccuracy)} over ${peopleChecked.length} cases (not gated)`);
}
if (underEscalated.length) {
  console.log('\n  UNDER-ESCALATED:');
  for (const r of underEscalated) console.log(`    ${r.id}: expected ${r.expect.severity}, got ${r.got?.severity}`);
}

// The deterministic backstops in Validate Triage. Every one of these is a case
// the model got wrong in the dangerous direction and the regex caught.
const floorApplied = results.filter((r) => r.floorApplied);
const injectionFlagged = results.filter((r) => r.injectionFlagged);
const needsReview = results.filter((r) => r.needsReview).length;
console.log(`        severity floor       ${floorApplied.length} raised to Critical by keyword backstop${floorApplied.length ? ': ' + floorApplied.map((r) => r.id).join(', ') : ''}`);
console.log(`        injection flagged    ${injectionFlagged.length}${injectionFlagged.length ? ': ' + injectionFlagged.map((r) => r.id).join(', ') : ''}`);
console.log(`        needs_review         ${needsReview}/${n} rows would reach a human for a second look`);

// The model's own fabrication rate, before the pipeline intervenes. This is the
// number that tells you whether the model got better; the gated metric above
// only tells you whether the safeguard held.
const modelFab = results.filter((r) => r.modelFabricated?.length);
const fabChecked = results.filter((r) => r.expect.no_fabrication).length;
console.log(`        model fabrication    ${modelFab.length}/${fabChecked} noise cases where the MODEL invented a detail (safeguard caught it, model unchanged)`);
if (modelFab.length) {
  for (const r of modelFab) console.log(`                             ${r.id}: ${r.modelFabricated.join(', ')}`);
}

if (missedCritical.length) {
  console.log('\n  MISSED CRITICAL — each of these is someone who does not get help:');
  for (const r of missedCritical) {
    console.log(`    ${r.id}: got ${r.got?.severity || r.error}`);
  }
}

// Confusion matrix on severity, which is where queue ordering lives.
console.log('\n  severity confusion (rows expected, cols got)');
console.log('              Critical  Urgent  Standard  other');
for (const expected of SEVERITIES) {
  const row = results.filter((r) => r.expect.severity === expected);
  const count = (s) => row.filter((r) => r.got?.severity === s).length;
  const other = row.filter((r) => !SEVERITIES.includes(r.got?.severity)).length;
  console.log(`    ${expected.padEnd(10)} ${String(count('Critical')).padStart(8)} ${String(count('Urgent')).padStart(7)} ${String(count('Standard')).padStart(9)} ${String(other).padStart(6)}`);
}

const failed =
  schemaViolations > BAR.schemaViolations ||
  criticalRecall < BAR.criticalRecall ||
  underEscalated.length > BAR.underEscalations ||
  overEscalationRate > BAR.overEscalationRate ||
  fabrications > BAR.fabrications ||
  categoryAccuracy < BAR.categoryAccuracy;

console.log('\n  ' + (failed ? 'NOT FIT FOR FIELD USE' : 'meets the current bar') + '\n');

const jsonOut = flag('json');
if (jsonOut) {
  writeFileSync(jsonOut, JSON.stringify({
    model: results[0]?.model, n,
    metrics: {
      schemaViolations, criticalRecall, fabrications, categoryAccuracy, peopleAccuracy,
      underEscalated: underEscalated.length, overEscalated: overEscalated.length, overEscalationRate,
      severityAccuracy, modelFabrications: modelFab.length,
    },
    bar: BAR, results,
  }, null, 2));
  console.log(`  wrote ${jsonOut}\n`);
}

process.exit(failed ? 1 : 0);
