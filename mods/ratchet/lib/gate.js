'use strict';
// ratchet mod — court-x2 gate policy (lib/gate.js).
// Exported contract: registerGate(on) — the register step (hooks/register.js,
// NOT edited here) must wire this after it creates the event bus:
//   require('../lib/gate.js').registerGate(on);
//
// Files lease: lib/gate.js. No register.js / hooks.json edits in this work order.
//
// Policy (full-ratchet design): guard tool.call events whose command contains
// `court-x2` — if the burn-ring receipt (azb-22-burn-ring.md) is standing RED
// OR the boot-burn receipt (azb-13-boot-burn.md) is not ALIVE, HOLD the tool
// call and answer it without running. The hold is liftable: when
// azb-22b-zombie-fix.md lands with a green ring re-run, the gate passes through.
// Unrelated bash commands are never held — the match is court-x2-specific.

const fs = require('fs');
const path = require('path');

const RECEIPTS_DIR =
  process.env.RATCHET_RECEIPTS_DIR ||
  '/Users/sac/smalt/docs/jira/v26.10.18/receipts';
const RING_RECEIPT = path.join(RECEIPTS_DIR, 'azb-22-burn-ring.md');
const BOOT_RECEIPT = path.join(RECEIPTS_DIR, 'azb-13-boot-burn.md');
const FIX_RECEIPT = path.join(RECEIPTS_DIR, 'azb-22b-zombie-fix.md');

const GATE_MESSAGE =
  'RATCHET GATE: court-x2 held — burn-ring is <verdict>; the ring\'s ZOMBIE_BEAM defect must be repaired and the ring re-run green first (azb-22b in flight)';

// Extract the typed standing from a receipt: first `Standing: **X**` (or
// `Standing: X` boldless) line. Returns null when absent.
function parseStanding(text) {
  if (typeof text !== 'string') return null;
  const m = text.match(/Standing:\s*\*{0,2}([A-Z_]+)/);
  return m ? m[1] : null;
}

function readReceipt(p) {
  try {
    return fs.readFileSync(p, 'utf8');
  } catch (_e) {
    return null;
  }
}

// The gate decision. Pure given the receipt texts (testable without disk).
//   { hold: false }                       — pass through
//   { hold: true, output, verdict }       — answer the call without running it
function decide({ ringText, bootText, fixText }) {
  const ringStanding = parseStanding(ringText);
  const bootStanding = parseStanding(bootText);

  // Lift condition first: a landed green azb-22b fix receipt lifts the hold
  // even while the ring receipt still reads RED (the fix receipt IS the ring
  // re-run green; the ring receipt is a point-in-time verdict).
  if (fixText != null) {
    const fixStanding = parseStanding(fixText);
    if (fixStanding === 'GREEN' || fixStanding === 'ALIVE') {
      return { hold: false, liftedBy: 'azb-22b-zombie-fix.md (' + fixStanding + ')' };
    }
  }

  // Fail-closed: a missing ring receipt is not a pass.
  const verdict = ringStanding || 'MISSING';
  if (verdict !== 'GREEN' && verdict !== 'ALIVE') {
    return { hold: true, output: GATE_MESSAGE.replace('<verdict>', verdict), verdict };
  }

  // Ring green: still require azb-13 boot-burn ALIVE.
  if (bootStanding !== 'ALIVE') {
    const bootVerdict = 'boot-burn ' + (bootStanding || 'MISSING');
    return {
      hold: true,
      output: 'RATCHET GATE: court-x2 held — azb-13 ' + bootVerdict + ' (not ALIVE); the ring\'s ZOMBIE_BEAM defect must be repaired and the ring re-run green first (azb-22b in flight)',
      verdict: bootVerdict,
    };
  }

  return { hold: false };
}

// Match is court-x2-specific: substring on the bash command. Anything else
// passes through untouched — unrelated commands are never held.
function isCourtX2(command) {
  return typeof command === 'string' && command.includes('court-x2');
}

function registerGate(on) {
  if (typeof on !== 'function') {
    throw new TypeError('ratchet.registerGate: registerGate(on) requires a callable `on`');
  }
  on('tool.call', (payload) => {
    const command =
      payload && payload.tool === 'Bash'
        ? payload.input && payload.input.command
        : payload && payload.input && payload.input.command;
    if (!isCourtX2(command)) return undefined; // pass through, unrelated command

    const decision = decide({
      ringText: readReceipt(RING_RECEIPT),
      bootText: readReceipt(BOOT_RECEIPT),
      fixText: readReceipt(FIX_RECEIPT),
    });
    if (!decision.hold) return undefined;

    // Guard-or-change contract: returning a hold answers the tool call
    // without running it. The message is the answer; nothing executes.
    return { hold: true, output: decision.output };
  });
}

module.exports = {
  RECEIPTS_DIR,
  RING_RECEIPT,
  BOOT_RECEIPT,
  FIX_RECEIPT,
  GATE_MESSAGE,
  registerGate,
  decide,
  isCourtX2,
  parseStanding,
};

if (require.main === module) {
  // Self-check: real receipts on disk, fake bus. Real output, real files.
  const handlers = {};
  registerGate((evt, h) => { handlers[evt] = h; });
  const result = handlers['tool.call']({ tool: 'Bash', input: { command: 'just court-x2' } });
  console.log('court-x2 ->', JSON.stringify(result));
  const pass = handlers['tool.call']({ tool: 'Bash', input: { command: 'just doctor' } });
  console.log('unrelated ->', JSON.stringify(pass), '(undefined = passes through)');
}
