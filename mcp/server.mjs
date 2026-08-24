#!/usr/bin/env node
//
// MCP server exposing the triage queue, read-only.
//
// JSON-RPC 2.0 over stdio, hand-rolled. No dependencies on purpose: `npm install`
// does not work during a blackout, and a node_modules tree is one more thing to
// get into the offline bundle and keep in step. Node 18+ has everything needed.
//
// Queries go through the MCP Tools API workflow, which runs them as `triage_ro`.
// That role cannot write — enforced by GRANT in db/init/03-readonly-role.sql, not
// by anything here. The model never supplies SQL; it picks a tool and fills in
// parameters, and the SQL is fixed in the workflow.
//
// Run it wherever node exists. Inside the stack that is the n8n container, which
// carries node already, so the host needs nothing installed:
//
//   docker compose exec -T n8n node /mcp/server.mjs
//
// Any MCP client speaking stdio can drive it. mcp/agent.mjs is the offline one.

const TOOLS_URL = process.env.MCP_TOOLS_URL || 'http://n8n:5678/webhook/mcp-tool';
const PROTOCOL_VERSION = '2025-06-18';
const REQUEST_TIMEOUT_MS = 15000;

// Tool schemas. Descriptions are written for a small local model, so they say
// plainly when to reach for each one — an 8B model given vague tool descriptions
// picks the wrong tool and then argues with the result.
const TOOLS = [
  {
    name: 'queue_summary',
    description: 'Current state of the whole queue as one row: how many requests are open, how many Critical are unacknowledged, how many are past their deadline, how many need human review, arrival rate, and whether AI triage is failing. Use this first for any question about overall load or whether the node is keeping up.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
  },
  {
    name: 'search_requests',
    description: 'Find open requests. Use `text` to match words the person actually wrote, their summary, or their location — e.g. "insulin", "oxygen", "Cedar". Filter by severity, category, status, or needs_review. Returns the raw message so you can read what was actually said.',
    inputSchema: {
      type: 'object',
      properties: {
        text: { type: 'string', description: 'Words to look for in the message, summary or location' },
        severity: { type: 'string', enum: ['Critical', 'Urgent', 'Standard'] },
        category: { type: 'string', enum: ['Medical', 'Structural', 'Supply'] },
        status: { type: 'string', enum: ['New', 'Acknowledged', 'Dispatched', 'Resolved', 'Duplicate'] },
        needs_review: { type: 'boolean', description: 'Only requests flagged for a human to read' },
        limit: { type: 'integer', description: 'Max rows, default 20, capped at 100' }
      },
      additionalProperties: false
    }
  },
  {
    name: 'get_request',
    description: 'Everything about one request by id, including every other submission from the same reporter. Use this before acting on a single request: a later message from the same household is usually an escalation, and reading one of four is misleading.',
    inputSchema: {
      type: 'object',
      properties: { id: { type: 'integer', description: 'The request id' } },
      required: ['id'],
      additionalProperties: false
    }
  },
  {
    name: 'requests_by_reporter',
    description: 'Every request from a reporter whose name matches, newest first, including resolved ones. Use it to answer "have we heard from them before" or "what did we already do for this family".',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'All or part of the reporter name' },
        limit: { type: 'integer', description: 'Max rows, default 20, capped at 100' }
      },
      required: ['name'],
      additionalProperties: false
    }
  },
  {
    name: 'location_hotspots',
    description: 'Open requests grouped by location, only places with more than one. Several DIFFERENT households reporting from one street usually means a structural cause — a gas leak, a collapse, a flooded block — which no single request reveals on its own. Use it for situational awareness rather than for one person.',
    inputSchema: {
      type: 'object',
      properties: { limit: { type: 'integer', description: 'Max locations, default 20, capped at 100' } },
      additionalProperties: false
    }
  },
  {
    name: 'review_pile',
    description: 'Requests flagged for a human, with the reason bucketed: suspected injection, fabricated summary, no detail given, floor overrode triage, model unavailable. For these rows the AI summary is not trustworthy — read raw_message.',
    inputSchema: {
      type: 'object',
      properties: { limit: { type: 'integer', description: 'Max rows, default 25, capped at 100' } },
      additionalProperties: false
    }
  }
];

async function callTool(name, args) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const res = await fetch(TOOLS_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ tool: name, args: args || {} }),
      signal: controller.signal
    });
    const body = await res.json().catch(() => null);
    if (!body) throw new Error('tools API returned an unreadable response (HTTP ' + res.status + ')');
    if (body.error) throw new Error(body.error);
    return body;
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------- JSON-RPC
function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}
function result(id, value) { send({ jsonrpc: '2.0', id, result: value }); }
function failure(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }); }

async function handle(msg) {
  const { id, method, params } = msg;
  // Notifications have no id and must not be answered.
  const isNotification = id === undefined || id === null;

  switch (method) {
    case 'initialize':
      return result(id, {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: 'offline-triage-node', version: '1.0.0' }
      });

    case 'notifications/initialized':
      return;

    case 'ping':
      return result(id, {});

    case 'tools/list':
      return result(id, { tools: TOOLS });

    case 'tools/call': {
      const name = params && params.name;
      const known = TOOLS.some((t) => t.name === name);
      if (!known) return failure(id, -32602, 'unknown tool: ' + name);
      try {
        const data = await callTool(name, params.arguments);
        // Content is text rather than structured, because that is what every MCP
        // client renders and what a local model reads back most reliably.
        return result(id, {
          content: [{ type: 'text', text: JSON.stringify(data, null, 1) }]
        });
      } catch (e) {
        // An MCP tool error, not a protocol error: the agent should see it and
        // be able to say "I could not read the queue" rather than dying.
        return result(id, {
          content: [{ type: 'text', text: 'Tool failed: ' + String(e.message || e) }],
          isError: true
        });
      }
    }

    default:
      if (isNotification) return;
      return failure(id, -32601, 'method not found: ' + method);
  }
}

let buffer = '';
// Requests are handled concurrently, so a slow query cannot block the next
// message. That means stdin can close while work is still in flight — exiting
// then would silently drop answers the client is waiting for, which is how the
// first version of this file lost six of eight replies.
let inFlight = 0;
let stdinClosed = false;

function maybeExit() {
  if (stdinClosed && inFlight === 0) process.exit(0);
}

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch (e) {
      failure(null, -32700, 'parse error');
      continue;
    }
    inFlight++;
    handle(msg)
      .catch((e) => {
        if (msg && msg.id != null) failure(msg.id, -32603, String(e.message || e));
      })
      .finally(() => { inFlight--; maybeExit(); });
  }
});

process.stdin.on('end', () => {
  stdinClosed = true;
  maybeExit();
  // Backstop, so a wedged upstream cannot leave the process alive forever.
  setTimeout(() => process.exit(0), REQUEST_TIMEOUT_MS + 2000).unref();
});
