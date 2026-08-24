#!/usr/bin/env node
//
// A coordinator asks a question in plain language; a local model answers it using
// the read-only tools in server.mjs.
//
//   docker compose exec -T n8n node /mcp/agent.mjs "how many people need insulin?"
//
// This exists because the usual MCP clients assume an internet connection to a
// hosted model, and this node will not have one. So the client is here, driving
// Ollama's tool calling over the same MCP server any other client would use —
// spawned over stdio, exactly as the protocol intends.
//
// Zero dependencies, for the same reason as server.mjs: `npm install` does not
// work in a blackout.
//
// It is an aid for reading a queue, never an authority on it. Every answer cites
// request ids so a coordinator can go and read the rows themselves.

import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const OLLAMA_URL = process.env.OLLAMA_URL || 'http://ollama:11434';
const MODEL = process.env.TRIAGE_AGENT_MODEL || 'llama3.1:8b';
// Small models will happily loop, calling the same tool repeatedly. Six rounds is
// enough for summary -> search -> detail and not enough to spin.
const MAX_ROUNDS = 6;

const question = process.argv.slice(2).join(' ').trim();
if (!question) {
  console.error('Usage: node agent.mjs "<question about the queue>"');
  process.exit(2);
}

// ------------------------------------------------------- MCP client over stdio
class McpClient {
  constructor(scriptPath) {
    this.child = spawn(process.execPath, [scriptPath], {
      stdio: ['pipe', 'pipe', 'inherit'],
      env: process.env
    });
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = '';
    this.child.stdout.setEncoding('utf8');
    this.child.stdout.on('data', (chunk) => this._onData(chunk));
  }

  _onData(chunk) {
    this.buffer += chunk;
    let i;
    while ((i = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, i).trim();
      this.buffer = this.buffer.slice(i + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      const waiter = this.pending.get(msg.id);
      if (!waiter) continue;
      this.pending.delete(msg.id);
      if (msg.error) waiter.reject(new Error(msg.error.message));
      else waiter.resolve(msg.result);
    }
  }

  request(method, params) {
    const id = this.nextId++;
    this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(method + ' timed out'));
      }, 30000);
    });
  }

  notify(method, params) {
    this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
  }

  close() { this.child.stdin.end(); this.child.kill(); }
}

// ------------------------------------------------------------------- prompt
const SYSTEM = [
  'You help a triage coordinator read an emergency request queue during a disaster.',
  'Answer only from what the tools return. Never invent a request, a name, a location or a number.',
  '',
  'How to work:',
  '- Call a tool before answering anything factual about the queue.',
  '- queue_summary first for questions about overall load or whether the node is keeping up.',
  '- search_requests to find specific needs; the text matches what people actually wrote.',
  '- location_hotspots when the question is about an area, or when several requests may share one cause.',
  '- get_request before advising on one specific request, because a later message from the same reporter is usually an escalation.',
  '',
  'When you answer:',
  '- Cite request ids so the coordinator can read the rows themselves.',
  '- Quote the words the person wrote when the detail matters.',
  '- Say plainly when the tools returned nothing rather than guessing.',
  '- Be brief. A coordinator is reading this between dispatches.',
  '- You are an aid for reading the queue, not the authority on who gets help first.'
].join('\n');

async function chat(messages, tools) {
  const res = await fetch(OLLAMA_URL + '/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: MODEL,
      stream: false,
      // Deterministic: the same question should give a coordinator the same answer.
      options: { temperature: 0 },
      tools,
      messages
    }),
    signal: AbortSignal.timeout(300000)
  });
  const body = await res.json();
  if (body.error) throw new Error(typeof body.error === 'string' ? body.error : 'ollama error');
  return body.message;
}

// --------------------------------------------------------------------- main
const mcp = new McpClient(join(HERE, 'server.mjs'));
let exitCode = 0;

try {
  await mcp.request('initialize', {
    protocolVersion: '2025-06-18',
    capabilities: {},
    clientInfo: { name: 'triage-agent', version: '1.0.0' }
  });
  mcp.notify('notifications/initialized', {});

  const listed = await mcp.request('tools/list', {});
  const tools = listed.tools.map((t) => ({
    type: 'function',
    function: { name: t.name, description: t.description, parameters: t.inputSchema }
  }));

  const messages = [
    { role: 'system', content: SYSTEM },
    { role: 'user', content: question }
  ];

  for (let round = 1; round <= MAX_ROUNDS; round++) {
    const reply = await chat(messages, tools);
    messages.push(reply);

    const calls = reply.tool_calls || [];
    if (!calls.length) {
      console.log('\n' + (reply.content || '(no answer)').trim() + '\n');
      break;
    }

    for (const call of calls) {
      const name = call.function?.name;
      let args = call.function?.arguments;
      if (typeof args === 'string') {
        try { args = JSON.parse(args); } catch { args = {}; }
      }
      // Printed so a coordinator can see what the answer rests on. An agent whose
      // reasoning is invisible cannot be checked, and this one must be checkable.
      process.stderr.write('  [' + name + ' ' + JSON.stringify(args || {}) + ']\n');

      let text;
      try {
        const out = await mcp.request('tools/call', { name, arguments: args || {} });
        text = (out.content || []).map((c) => c.text).join('\n');
        if (out.isError) text = 'ERROR: ' + text;
      } catch (e) {
        text = 'ERROR: ' + String(e.message || e);
      }
      messages.push({ role: 'tool', content: text.slice(0, 12000) });
    }

    if (round === MAX_ROUNDS) {
      console.log('\nStopped after ' + MAX_ROUNDS + ' tool rounds without a final answer.');
      console.log('Read the queue directly — the tool output above is what it found.\n');
      exitCode = 1;
    }
  }
} catch (e) {
  console.error('\nAgent failed: ' + String(e.message || e));
  console.error('The queue itself is unaffected. Read it directly in NocoDB.\n');
  exitCode = 1;
} finally {
  mcp.close();
}

process.exit(exitCode);
