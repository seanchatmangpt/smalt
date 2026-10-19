'use strict';
// R9 lane — lib/gate.js tests. Fixtures under test/fixtures/{red,green,boot-stale}
// are REAL repo receipts with mutated verdict lines (see fixture headers).
// gate.js reads RATCHET_RECEIPTS_DIR once at require time, so each scenario
// re-requires it fresh via loadGate(dir). Chicago: real receipt files on disk,
// the bus is a plain handler map.
// Run: node --test /Users/sac/smalt/mods/ratchet/test/

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const GATE_PATH = path.resolve(__dirname, '../lib/gate.js');
const FIXTURES = path.join(__dirname, 'fixtures');

function loadGate(dir) {
  delete require.cache[require.resolve(GATE_PATH)];
  process.env.RATCHET_RECEIPTS_DIR = path.join(FIXTURES, dir);
  return require(GATE_PATH);
}

function bus(gate) {
  const handlers = {};
  gate.registerGate((evt, h) => { handlers[evt] = h; });
  return handlers;
}

test('ring RED holds court-x2 (real RED receipt copy as fixture)', () => {
  const gate = loadGate('red');
  const h = bus(gate);
  const result = h['tool.call']({ tool: 'Bash', input: { command: 'just court-x2' } });
  assert.ok(result && result.hold, 'court-x2 must be held while the ring is RED');
  assert.match(result.output, /RATCHET GATE/);
  assert.match(result.output, /RED/);
  // the typed verdict lives on the pure decision, not the bus return shape
  const ring = fs.readFileSync(path.join(FIXTURES, 'red/azb-22-burn-ring.md'), 'utf8');
  const boot = fs.readFileSync(path.join(FIXTURES, 'red/azb-13-boot-burn.md'), 'utf8');
  assert.equal(gate.decide({ ringText: ring, bootText: boot, fixText: null }).verdict, 'RED');
});

test('green azb-22b fix fixture lifts the hold — court-x2 passes through', () => {
  const gate = loadGate('green');
  const h = bus(gate);
  const result = h['tool.call']({ tool: 'Bash', input: { command: 'just court-x2' } });
  assert.equal(result, undefined, 'green fix receipt lifts the hold (pass through)');
});

test('green ring but boot-burn not ALIVE still holds', () => {
  const gate = loadGate('boot-stale');
  const h = bus(gate);
  const result = h['tool.call']({ tool: 'Bash', input: { command: 'just court-x2' } });
  assert.ok(result && result.hold);
  assert.match(result.output, /azb-13/);
  assert.match(result.output, /PARTIAL_ALIVE/);
});

test('missing ring receipt fails CLOSED, never passes', () => {
  const gate = loadGate('red');
  const h = bus(gate);
  // point at an empty dir: ring + boot + fix all unreadable
  process.env.RATCHET_RECEIPTS_DIR = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'gate-empty-'));
  delete require.cache[require.resolve(GATE_PATH)];
  const empty = require(GATE_PATH);
  const h2 = bus(empty);
  const result = h2['tool.call']({ tool: 'Bash', input: { command: 'just court-x2' } });
  assert.ok(result && result.hold);
  assert.match(result.output, /MISSING/);
});

test('unrelated bash passes untouched even with the ring RED', () => {
  const gate = loadGate('red');
  const h = bus(gate);
  for (const cmd of ['just doctor', 'mix test', 'ls -la', 'just court', 'echo court-x2-notes.md']) {
    // 'just court' (no -x2) and a filename containing court-x2 are still
    // substring matches by design — assert the doc'd contract precisely:
    // commands NOT containing 'court-x2' pass through.
    if (!cmd.includes('court-x2')) {
      assert.equal(h['tool.call']({ tool: 'Bash', input: { command: cmd } }), undefined, cmd);
    }
  }
});

test('parseStanding reads typed standings from the real receipt texts', () => {
  const gate = loadGate('red');
  const ring = fs.readFileSync(path.join(FIXTURES, 'red/azb-22-burn-ring.md'), 'utf8');
  const boot = fs.readFileSync(path.join(FIXTURES, 'red/azb-13-boot-burn.md'), 'utf8');
  assert.match(gate.parseStanding(ring), /^RED/);
  assert.equal(gate.parseStanding(boot), 'ALIVE');
  assert.equal(gate.parseStanding('no standing line here'), null);
});

test('pure decide(): RED ring, no fix -> hold; green fix lifts even with RED ring', () => {
  const gate = loadGate('red');
  const ringRed = fs.readFileSync(path.join(FIXTURES, 'red/azb-22-burn-ring.md'), 'utf8');
  const bootAlive = fs.readFileSync(path.join(FIXTURES, 'red/azb-13-boot-burn.md'), 'utf8');
  const fixGreen = fs.readFileSync(path.join(FIXTURES, 'green/azb-22b-zombie-fix.md'), 'utf8');
  const ringGreen = fs.readFileSync(path.join(FIXTURES, 'green/azb-22-burn-ring.md'), 'utf8');

  assert.equal(gate.decide({ ringText: ringRed, bootText: bootAlive, fixText: null }).hold, true);
  assert.equal(
    gate.decide({ ringText: ringRed, bootText: bootAlive, fixText: fixGreen }).hold,
    false,
    'a landed green azb-22b receipt lifts the hold',
  );
  assert.equal(
    gate.decide({ ringText: ringGreen, bootText: bootAlive, fixText: null }).hold,
    false,
    'green ring with ALIVE boot passes',
  );
  // a RED fix receipt does NOT lift
  const fixRed = fixGreen.replace('GREEN', 'RED');
  assert.equal(gate.decide({ ringText: ringRed, bootText: bootAlive, fixText: fixRed }).hold, true);
});
