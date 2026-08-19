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
const BAR = {
  schemaViolations: 0,
  criticalRecall: 1.0,
  severityAccuracy: 0.75,
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
function loadNormalizeIntake(path) {
  let workflow;
  try {
    workflow = JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    // Fall back to the repo-relative copy so the harness also runs from a
    // checkout, not just from inside the container.
    const local = join(HERE, '..', 'n8n', 'workflows', 'sos-intake-triage.json');
    workflow = JSON.parse(readFileSync(local, 'utf8'));
  }
  const node = workflow.nodes.find((n) => n.name === 'Normalize Intake');
  if (!node?.parameters?.jsCode) {
    throw new Error('Normalize Intake node or its jsCode not found in the workflow');
  }
  // The Code node body is a function body referencing $input and returning
  // { json: ... }. Nothing else from the n8n runtime is used, deliberately:
  // n8n 2.x denies Code nodes access to $env and throws on contact.
  return new Function('$input', node.parameters.jsCode);
}

const normalize = loadNormalizeIntake(WORKFLOW);

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
    const response = await fetch(`${OLLAMA_URL}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(180000),
    });
    const body = await response.json();
    if (body.error) throw new Error(typeof body.error === 'string' ? body.error : 'ollama error');

    const parsed = JSON.parse(body.message.content);
    record.got = parsed;

    // --- schema, the hard contract
    if (!SEVERITIES.includes(parsed.severity)) record.problems.push(`schema: severity=${JSON.stringify(parsed.severity)}`);
    if (!CATEGORIES.includes(parsed.category)) record.problems.push(`schema: category=${JSON.stringify(parsed.category)}`);
    if (typeof parsed.summary !== 'string') record.problems.push('schema: summary not a string');
    if (!Number.isInteger(parsed.people_affected)) record.problems.push('schema: people_affected not an integer');
    record.schemaValid = record.problems.length === 0;

    // --- labels
    const sevOk = testCase.expect.severity_ok || [testCase.expect.severity];
    const catOk = testCase.expect.category_ok || [testCase.expect.category];
    record.severityMatch = sevOk.includes(parsed.severity);
    record.categoryMatch = catOk.includes(parsed.category);

    if (testCase.expect.people !== undefined) {
      const peopleOk = testCase.expect.people_ok || [testCase.expect.people];
      record.peopleMatch = peopleOk.includes(parsed.people_affected);
    }

    // --- fabrication
    if (testCase.expect.no_fabrication) {
      const invented = fabricatedTerms(parsed.summary, testCase.message);
      record.fabricated = invented;
      if (invented.length) record.problems.push(`fabricated: ${invented.join(', ')}`);
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

const expectedCritical = results.filter((r) => (r.expect.severity_ok || [r.expect.severity]).includes('Critical') && r.expect.severity === 'Critical');
const missedCritical = expectedCritical.filter((r) => r.got?.severity !== 'Critical');
const criticalRecall = expectedCritical.length ? 1 - missedCritical.length / expectedCritical.length : 1;

const overEscalated = results.filter((r) => r.expect.severity === 'Standard' && r.got?.severity === 'Critical');

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
console.log(`  ${verdict('fabrications     ', fabrications, BAR.fabrications, (v, b) => v <= b)}   ${fabrications} (bar ${BAR.fabrications})`);
console.log(`  ${verdict('severity accuracy', severityAccuracy, BAR.severityAccuracy)}   ${pct(severityAccuracy)} (bar ${pct(BAR.severityAccuracy)})`);
console.log(`  ${verdict('category accuracy', categoryAccuracy, BAR.categoryAccuracy)}   ${pct(categoryAccuracy)} (bar ${pct(BAR.categoryAccuracy)})`);
if (peopleAccuracy !== null) {
  console.log(`        people_affected      ${pct(peopleAccuracy)} over ${peopleChecked.length} cases (not gated)`);
}
console.log(`        over-escalated       ${overEscalated.length} Standard cases read as Critical (noise, not a failure)`);

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
  fabrications > BAR.fabrications ||
  severityAccuracy < BAR.severityAccuracy ||
  categoryAccuracy < BAR.categoryAccuracy;

console.log('\n  ' + (failed ? 'NOT FIT FOR FIELD USE' : 'meets the current bar') + '\n');

const jsonOut = flag('json');
if (jsonOut) {
  writeFileSync(jsonOut, JSON.stringify({
    model: results[0]?.model, n,
    metrics: { schemaViolations, criticalRecall, fabrications, severityAccuracy, categoryAccuracy, peopleAccuracy, overEscalated: overEscalated.length },
    bar: BAR, results,
  }, null, 2));
  console.log(`  wrote ${jsonOut}\n`);
}

process.exit(failed ? 1 : 0);
