'use strict';
// R9 lane — lib/commands.js tests: mode transitions persist through the
// atomic tmp+rename write, decisionLog is appended + bounded, /ratchet status
// renders from the REAL TICKETS.md. Chicago: real temp state files, real doc.
// Run: node --test /Users/sac/smalt/mods/ratchet/test/

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const commands = require('../lib/commands.js');
const TICKETS_PATH = '/Users/sac/smalt/docs/jira/v26.10.18/azsim-burn/TICKETS.md';

function tmpState(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ratchet-cmds-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return path.join(dir, 'ratchet-state.json');
}

test('loadState on a fresh path initializes DEFAULT_MODE and persists the file', (t) => {
  const p = tmpState(t);
  const s = commands.loadState(p);
  assert.equal(s.mode, commands.DEFAULT_MODE); // OBSERVE
  assert.ok(fs.existsSync(p), 'initial state must be persisted');
  const onDisk = JSON.parse(fs.readFileSync(p, 'utf8'));
  assert.equal(onDisk.mode, 'OBSERVE');
});

test('setMode transition persists and appends a decisionLog entry', (t) => {
  const p = tmpState(t);
  const s0 = commands.loadState(p);
  const { state: s1, changed } = commands.setMode(s0, 'AUTO', p);
  assert.equal(changed, true);
  assert.equal(s1.mode, 'AUTO');
  const onDisk = JSON.parse(fs.readFileSync(p, 'utf8'));
  assert.equal(onDisk.mode, 'AUTO', 'AUTO must survive the process on disk');
  assert.equal(onDisk.decisionLog.at(-1).kind, 'mode-set');
  assert.equal(onDisk.decisionLog.at(-1).from, 'OBSERVE');
  assert.equal(onDisk.decisionLog.at(-1).to, 'AUTO');

  // OFF from AUTO; log records the full transition chain
  const { state: s2, changed: c2 } = commands.setMode(s1, 'OFF', p);
  assert.equal(c2, true);
  assert.equal(s2.mode, 'OFF');
  const onDisk2 = JSON.parse(fs.readFileSync(p, 'utf8'));
  assert.equal(onDisk2.mode, 'OFF');
  assert.deepEqual(
    onDisk2.decisionLog.slice(-2).map((d) => `${d.from}->${d.to}`),
    ['OBSERVE->AUTO', 'AUTO->OFF'],
  );

  // idempotent set: same mode -> changed=false, mode still persisted
  const { changed: c3 } = commands.setMode(s2, 'OFF', p);
  assert.equal(c3, false);
});

test('loadState merges over an existing file without clobbering lane fields', (t) => {
  const p = tmpState(t);
  fs.writeFileSync(p, JSON.stringify({
    mode: 'AUTO',
    lastDispatch: '2026-10-18T00:00:00Z',
    agentsInFlight: 7,
    decisionLog: [{ at: 'x', kind: 'tick' }],
  }));
  const s = commands.loadState(p);
  assert.equal(s.mode, 'AUTO');
  assert.equal(s.lastDispatch, '2026-10-18T00:00:00Z');
  assert.equal(s.agentsInFlight, 7);
  assert.equal(s.ticks, 0, 'missing fields get defaults, not undefined');
  // corrupt mode -> falls back to DEFAULT_MODE (lane-owned, never dropped)
  fs.writeFileSync(p, JSON.stringify({ mode: 'BOGUS' }));
  assert.equal(commands.loadState(p).mode, 'OBSERVE');
});

test('decisionLog is bounded at 200 entries', (t) => {
  const p = tmpState(t);
  let s = commands.loadState(p);
  for (let i = 0; i < 250; i++) s = commands.logDecision(s, { kind: 'tick', i }, p);
  const onDisk = JSON.parse(fs.readFileSync(p, 'utf8'));
  assert.equal(onDisk.decisionLog.length, 200);
  assert.equal(onDisk.decisionLog.at(-1).i, 249);
});

test('readTickets + renderStatus against the real TICKETS.md', () => {
  const tickets = commands.readTickets(fs.readFileSync(TICKETS_PATH, 'utf8'));
  assert.equal(tickets.reason, 'ok');
  assert.ok(tickets.landed + tickets.open > 0);
  assert.match(tickets.next, /^AZB-\d{2}$/);
  const text = commands.renderStatus({ mode: 'OBSERVE', decisionLog: [] }, tickets);
  assert.match(text, /mode: OBSERVE/);
  assert.match(text, new RegExp(`landed: ${tickets.landed}`));
  assert.match(text, /next-dispatchable: AZB-/);
});

test('readTickets on unreadable input degrades typed, not throws', () => {
  const r = commands.readTickets(null);
  assert.equal(r.reason, 'tickets-file-unreadable');
  assert.equal(r.next, null);
});
