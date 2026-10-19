'use strict';

// ratchet mod — commands lane (R6). Adds /ratchet, /ratchet-mode, /ratchet-off.
// Per mods docs "Add a command or a tool": register each command in a
// session.start hook via $.command.register, handle its name in a command.run
// hook. `immediate: true` on the registration lets the command run while
// Claude is working — no Claude turn. The command.run handler returns
// { text }, which prints in the transcript; it never calls next() because
// the command has no other behavior.

const fs = require('fs');
const path = require('path');

const STATE_PATH = '/Users/sac/smalt/docs/jira/v26.10.18/rewrite-drafts/ratchet-state.json';
const TICKETS_PATH = '/Users/sac/smalt/docs/jira/v26.10.18/azsim-burn/TICKETS.md';

const MODES = ['AUTO', 'OBSERVE', 'OFF'];
const DEFAULT_MODE = 'OBSERVE';
const DECISION_LOG_LIMIT = 200;

// ---------- state ----------

// Atomic write: same-directory tmp file + rename (POSIX-atomic).
function writeStateAtomic(state, statePath) {
  const p = statePath || STATE_PATH;
  const tmp = path.join(path.dirname(p), `.${path.basename(p)}.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n');
  fs.renameSync(tmp, p);
  return state;
}

// Read state; absent/unreadable → initialize with mode default and persist.
// Merges over the file's own fields so timer/inject/gate lanes' fields
// (lastDispatch, agentsInFlight, ticks, decisionLog, ...) survive.
function loadState(statePath) {
  const p = statePath || STATE_PATH;
  try {
    const parsed = JSON.parse(fs.readFileSync(p, 'utf8'));
    const out = {
      intervalMinutes: 5,
      capacity: 20,
      agentsInFlight: 0,
      lastDispatch: null,
      ticks: 0,
      mode: DEFAULT_MODE,
      decisionLog: [],
      ...parsed,
    };
    // mode is lane-owned: never let a partial file drop it silently
    if (!MODES.includes(out.mode)) out.mode = DEFAULT_MODE;
    return out;
  } catch {
    const initial = { mode: DEFAULT_MODE, decisionLog: [], ticks: 0 };
    writeStateAtomic(initial, p);
    return initial;
  }
}

// Append to the decision log (bounded), then persist atomically.
function logDecision(state, entry, statePath) {
  const log = Array.isArray(state.decisionLog) ? state.decisionLog : [];
  log.push({ at: new Date().toISOString(), ...entry });
  state.decisionLog = log.slice(-DECISION_LOG_LIMIT);
  writeStateAtomic(state, statePath);
  return state;
}

// ---------- tickets ----------

// Landed = AZB ticket lines marked done (receipt/✅/[x]/DONE); open = all AZB
// ticket lines minus landed; next-dispatchable = first open line.
function readTickets(ticketsText) {
  if (typeof ticketsText !== 'string') {
    return { landed: 0, open: 0, next: null, reason: 'tickets-file-unreadable' };
  }
  const azb = (re) =>
    ticketsText
      .split('\n')
      .filter((l) => /\bAZB-\d+\b/.test(l))
      .filter(re);
  const all = azb(() => true);
  const done = azb((l) => /receipt(ed)?\b|DONE|✅|\[x\]/i.test(l));
  const openLines = all.filter((l) => !done.includes(l));
  const nextLine = openLines[0] || null;
  return {
    landed: done.length,
    open: openLines.length,
    next: nextLine ? (nextLine.match(/\bAZB-\d+\b/) || [null])[0] : null,
    reason: 'ok',
  };
}

function safeRead(p) {
  try {
    return fs.readFileSync(p, 'utf8');
  } catch {
    return null;
  }
}

// ---------- mode transitions ----------

// Set mode with decision-log entry; returns { state, changed }.
function setMode(state, mode, statePath) {
  const prev = state.mode;
  state.mode = mode;
  logDecision(state, { kind: 'mode-set', from: prev, to: mode }, statePath);
  return { state, changed: prev !== mode };
}

// ---------- renderers ----------

function renderStatus(state, tickets) {
  const mode = state.mode || DEFAULT_MODE;
  const modeNote =
    mode === 'AUTO'
      ? 'injects dispatches (timer may submit prompts)'
      : mode === 'OBSERVE'
        ? 'panel only — no injection'
        : 'no injection; panel stays';
  const log = Array.isArray(state.decisionLog) ? state.decisionLog : [];
  const tail = log
    .slice(-5)
    .map((d) => `  ${d.at} ${d.kind}${d.from ? ` ${d.from}->${d.to}` : ''}`)
    .join('\n');
  const lines = [
    'ratchet:',
    `  mode: ${mode} (${modeNote})`,
    `  landed: ${tickets.landed}  open: ${tickets.open}`,
    `  next-dispatchable: ${tickets.next || '(none)'}`,
    `  agentsInFlight: ${state.agentsInFlight || 0}/${state.capacity || 20}  ticks: ${state.ticks || 0}  lastDispatch: ${state.lastDispatch || 'never'}`,
    tickets.reason !== 'ok' ? `  (tickets: ${tickets.reason})` : null,
    '  decisionLog tail:',
    tail || '  (empty)',
  ];
  return lines.filter((l) => l !== null).join('\n');
}

// ---------- registration ----------

// registerCommands(on) — `on` is the mod hook registrar passed to register().
// Registers the three commands in session.start and handles command.run per
// name. R9 (integration lane) wires this from hooks/register.js — wiring line:
//   const { registerCommands } = require('../lib/commands.js'); registerCommands(on)
// (commands.js is registered LAST / try-caught per docs: $.command.register
// throws on a taken name and a throwing hook is skipped entirely).
function registerCommands(on) {
  if (typeof on !== 'function') {
    throw new TypeError('ratchet.registerCommands: registerCommands(on) requires a callable `on`');
  }

  // Claude Code waits for session.start before the first prompt, so the
  // commands are available from the first turn.
  on('session.start', async ($, e, next) => {
    // immediate: true → /ratchet* runs at once, even while Claude is working
    // (mods docs, "Add a command": "To let the command run while Claude is
    // working, add immediate: true").
    await $.command.register({
      name: 'ratchet',
      description: 'Show ratchet state: landed/open tickets, next dispatchable, mode, decisionLog tail',
    });
    await $.command.register({
      name: 'ratchet-mode',
      description: 'Set ratchet mode: AUTO (inject dispatches) or OBSERVE (panel only)',
      argumentHint: '<AUTO|OBSERVE>',
      immediate: true,
    });
    await $.command.register({
      name: 'ratchet-off',
      description: 'Set ratchet mode OFF (no injection, panel stays)',
      immediate: true,
    });
    return next(e);
  });

  on('command.run', { command: 'ratchet' }, async () => {
    const state = loadState();
    const tickets = readTickets(safeRead(TICKETS_PATH));
    return { text: renderStatus(state, tickets) };
  });

  on('command.run', { command: 'ratchet-mode' }, async ($, e) => {
    const arg = String((e && e.args) || '').trim().toUpperCase();
    if (arg !== 'AUTO' && arg !== 'OBSERVE') {
      return { text: `ratchet-mode: refuse '${arg || '(empty)'}' — usage: /ratchet-mode <AUTO|OBSERVE>` };
    }
    const state = loadState();
    const { changed } = setMode(state, arg);
    return {
      text: `ratchet mode: ${arg}${changed ? '' : ' (unchanged)'}${arg === 'AUTO' ? ' — timer injects dispatches' : ' — panel only, no injection'}`,
    };
  });

  on('command.run', { command: 'ratchet-off' }, async () => {
    const state = loadState();
    const { changed } = setMode(state, 'OFF');
    return {
      text: `ratchet mode: OFF (no injection, panel stays)${changed ? '' : ' (unchanged)'}`,
    };
  });
}

module.exports = {
  MODES,
  DEFAULT_MODE,
  STATE_PATH,
  TICKETS_PATH,
  registerCommands,
  loadState,
  writeStateAtomic,
  setMode,
  logDecision,
  readTickets,
  renderStatus,
};
