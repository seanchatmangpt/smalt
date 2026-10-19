'use strict';
// ratchet mod — turn-complete enforcement hook.
// Exported contract: registerTurn(on) — the register step (register.js, owned
// by the parent work order) calls this with an event-bus `on(event, handler)`
// per mods docs "React to events". This file owns ONLY turn.complete.
//
// Files lease: hooks/turn.js. register.js / hooks.json are NOT edited here;
// wiring note for the parent:
//   hooks.json already routes Register -> node "${CLAUDE_PLUGIN_ROOT}/hooks/register.js";
//   register.js must `require('./turn.js').registerTurn(on)` after it creates the bus.

const fs = require('fs');
const path = require('path');

const MOD_ROOT = path.resolve(__dirname, '..');
const STATE_PATH = process.env.RATCHET_STATE_PATH || path.join(MOD_ROOT, 'state.json');

// Try lib/state.js / lib/inject.js if a sibling work order has landed them;
// otherwise inline the minimal equivalents below (same guards, same file).
let libState = null;
let libInject = null;
try { libState = require('../lib/state.js'); } catch (_e) { /* inline path */ }
try { libInject = require('../lib/inject.js'); } catch (_e) { /* inline path */ }

const MAX_LOG = 50;          // decisionLog cap
const DEDUP_MS = 5 * 60 * 1000; // 5-minute dispatch dedup window
const DEFAULT_CAPACITY = 20;    // ratchet target: N agents in flight

function readState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_PATH, 'utf8'));
  } catch (_e) {
    return { tickets: [], decisionLog: [], lastDispatchAt: 0, dispatchLock: false };
  }
}

function writeState(state) {
  if (Array.isArray(state.decisionLog) && state.decisionLog.length > MAX_LOG) {
    state.decisionLog = state.decisionLog.slice(-MAX_LOG);
  }
  fs.mkdirSync(path.dirname(STATE_PATH), { recursive: true });
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2) + '\n');
}

function logDecision(state, decision, detail) {
  state.decisionLog = Array.isArray(state.decisionLog) ? state.decisionLog : [];
  state.decisionLog.push({
    at: new Date().toISOString(),
    event: 'turn.complete',
    decision,
    detail,
  });
  writeState(state);
}

// deps satisfied: every ticket id in `deps` is DONE.
function depsSatisfied(ticket, ticketsById) {
  return (ticket.deps || []).every((d) => {
    const dep = ticketsById.get(d);
    return dep && dep.status === 'DONE';
  });
}

function computeNextAction(state, now) {
  const tickets = Array.isArray(state.tickets) ? state.tickets : [];
  const byId = new Map(tickets.map((t) => [t.id, t]));
  const open = tickets.filter((t) => t.status === 'OPEN');
  const inFlight = tickets.filter((t) => t.status === 'IN_FLIGHT').length;
  const capacity = state.capacity == null ? DEFAULT_CAPACITY : state.capacity;

  if (state.dispatchLock) {
    return { action: 'SKIP', reason: 'dispatchLock held' };
  }
  if (state.lastDispatchAt && now - state.lastDispatchAt < DEDUP_MS) {
    return { action: 'SKIP', reason: 'dedup window (5m) since last dispatch' };
  }
  if (inFlight >= capacity) {
    return { action: 'IDLE', reason: `capacity full (${inFlight}/${capacity})` };
  }
  const ready = open.find((t) => depsSatisfied(t, byId));
  if (!ready) {
    return {
      action: open.length === 0 ? 'DONE' : 'BLOCKED',
      reason: open.length === 0
        ? 'no OPEN tickets'
        : `OPEN tickets exist but deps unsatisfied: ${open.map((t) => t.id).join(',')}`,
    };
  }
  return { action: 'DISPATCH', reason: `ticket ${ready.id} OPEN with deps satisfied`, ticket: ready };
}

// Inline bounded inject (used only when lib/inject.js is absent). Same guards
// as the lib contract: 5-min dedup + dispatchLock + named-ticket prompt.
function inlineInject(ticket, state, now) {
  state.dispatchLock = true;
  state.lastDispatchAt = now;
  if (ticket.status === 'OPEN') ticket.status = 'IN_FLIGHT';
  writeState(state);
  // The actual agent fan-out is the register.js concern; the hook's bounded
  // responsibility ends at the state transition + named-ticket prompt record.
  return {
    injected: true,
    ticket: ticket.id,
    prompt: `Work ticket ${ticket.id}: ${ticket.title || ticket.description || ''}`.trim(),
    via: 'inline',
  };
}

function registerTurn(on) {
  on('turn.complete', (payload) => {
    const now = Date.now();
    const state = readState();
    try {
      // If lib/state.js exists, let it own computation; else inline.
      const computed = libState && typeof libState.computeNextAction === 'function'
        ? libState.computeNextAction(state, now)
        : computeNextAction(state, now);

      if (computed.action === 'DISPATCH' && computed.ticket) {
        let result;
        if (libInject && typeof libInject.injectDispatch === 'function') {
          result = libInject.injectDispatch(computed.ticket, state, now);
        } else {
          result = inlineInject(computed.ticket, state, now);
        }
        logDecision(state, 'DISPATCH', {
          ticket: computed.ticket.id,
          via: result.via || 'lib',
          turn: payload && payload.turnId,
        });
      } else {
        logDecision(state, computed.action, {
          reason: computed.reason,
          turn: payload && payload.turnId,
        });
      }
    } catch (err) {
      // Never throw out of a hook — record the failure as a decision.
      try {
        logDecision(state, 'ERROR', { error: String(err && err.message || err) });
      } catch (_e2) { /* state unwritable; nothing further to do */ }
    }
  });
}

module.exports = { registerTurn };

if (require.main === module) {
  // Self-check: register against a fake bus, fire turn.complete, show state.
  const handlers = {};
  registerTurn((evt, h) => { handlers[evt] = h; });
  handlers['turn.complete']({ turnId: 'selftest' });
  console.log('selftest ok — state at', STATE_PATH);
}
