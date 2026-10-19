'use strict';
// ratchet/lib/inject.js — timer + turn.complete seam (R5): ratchet tick on turn
// completion, and a time-based inject when the last tick is stale (> TICK_MIN).
'use strict';

const state = require('./state');

const TICK_MIN = 15;

function turnComplete(cwd, summary) {
  const s = state.record(cwd, 'turn-complete', String(summary || '').slice(0, 80));
  return s;
}

// Timer: no native timer hook exists, so the tick is evaluated lazily — every
// panel render / turn end checks staleness of the last tick and injects once.
function tick(cwd, now = Date.now()) {
  const s = state.load(cwd);
  const last = s.events.filter((e) => e.kind === 'timer-tick').pop();
  const stale = !last || now - Date.parse(last.t) > TICK_MIN * 60000;
  if (!stale) return null;
  state.record(cwd, 'timer-tick', `interval ${TICK_MIN}m`);
  return `ratchet tick: ${TICK_MIN}m since last tick; level=${state.load(cwd).ratchet}`;
}

// registerTurn(api) — api = { onTurn(fn) }; turn completion + lazy timer tick.
function registerTurn(api) {
  api.onTurn((cwd, summary) => turnComplete(cwd, summary));
  api.onTurn((cwd) => tick(cwd));
}

module.exports = { turnComplete, tick, registerTurn, TICK_MIN };
