'use strict';
// ratchet/lib/panel.js — ui.render panel seam (R3): status lines from shared state.
'use strict';

const state = require('./state');

function render(cwd) {
  const s = state.load(cwd);
  const bars = Math.min(s.ratchet, 10);
  return [
    `ratchet ${'//'.repeat(bars) || '.'} level=${s.ratchet} blocks=${s.blocks} events=${s.events.length}`,
    ...s.events.slice(-3).map((e) => `  ${e.t} ${e.kind} ${e.detail || ''}`.trimEnd()),
  ].join('\n');
}

// registerPanel(api) — api = { onRender(fn) }; the register.js wiring calls this
// with a minimal api object backed by the hooks config it emits.
function registerPanel(api) {
  api.onRender((cwd) => render(cwd));
}

module.exports = { render, registerPanel };
