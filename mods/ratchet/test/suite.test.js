'use strict';
// End-to-end tests for the ratchet hook suite. node --test test/
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { execFileSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const ROOT = path.resolve(__dirname, '..');
const RUN = path.join(ROOT, 'hooks', 'run.js');
const REGISTER = path.join(ROOT, 'hooks', 'register.js');
const TMP = fs.mkdtempSync('/tmp/ratchet-test-');

function runKind(kind, payload) {
  return execFileSync('node', [RUN, kind], {
    input: JSON.stringify({ cwd: TMP, ...payload }),
    encoding: 'utf8',
  });
}

test('register.js emits valid hooks config with all four seams wired', () => {
  const out = JSON.parse(execFileSync('node', [REGISTER], { encoding: 'utf8' }));
  const h = out.hooks;
  assert.ok(h.UserPromptSubmit.length >= 1, 'panel seam present');
  assert.ok(h.PreToolUse[0].matcher.includes('Bash'));
  assert.ok(h.SessionStart.length >= 1);
  assert.ok(h.SessionEnd.length >= 1);
  const cmd = h.PreToolUse[0].hooks[0].command;
  assert.match(cmd, /hooks\/run\.js" gate$/);
});

test('register.js wiring collector holds handlers from all four register* fns', () => {
  const { api } = require(REGISTER);
  assert.ok(api.handlers.render.length >= 1, 'registerPanel wired');
  assert.ok(api.handlers.turn.length >= 2, 'registerTurn wired (turn + tick)');
  assert.ok(api.handlers.gate.length >= 1, 'registerGate wired');
  assert.ok(api.handlers.commands.length >= 2, 'registerCommands wired');
});

test('gate blocks rm -rf / via run.js gate kind (deny JSON emitted)', () => {
  const out = runKind('gate', { tool_name: 'Bash', tool_input: { command: 'rm -rf /' } });
  const j = JSON.parse(out);
  assert.equal(j.hookSpecificOutput.permissionDecision, 'deny');
  assert.match(j.hookSpecificOutput.permissionDecisionReason, /filesystem root/);
});

test('gate allows an ordinary bash command (silent allow, no stdout)', () => {
  const out = runKind('gate', {
    tool_name: 'Bash',
    tool_input: { command: 'ls -la /tmp' },
  });
  assert.equal(out, '');
});

test('gate blocks hand-edit of a generated artifact path', () => {
  const out = runKind('gate', {
    tool_name: 'Edit',
    tool_input: { file_path: path.join(ROOT, 'docs/ERROR_CODES.md') },
  });
  assert.match(out, /regenerate, don't patch/);
});

test('turn kind records a turn-complete event', () => {
  runKind('turn', { tool_name: 'Task' });
  const s = JSON.parse(fs.readFileSync(require('../hooks/lib/state').statePath(TMP)));
  assert.ok(s.events.some((e) => e.kind === 'turn-complete'));
});

test('panel kind emits additionalContext with ratchet line', () => {
  const out = runKind('panel', {});
  const j = JSON.parse(out);
  assert.match(j.hookSpecificOutput.additionalContext, /ratchet .*level=/);
});

test('commands dispatch: status renders, reset clears, unknown refused', () => {
  assert.match(runKind('commands', { command: 'ratchet:status' }), /level=/);
  assert.match(runKind('commands', { command: 'ratchet:reset' }), /reset/);
  const s = JSON.parse(fs.readFileSync(require('../hooks/lib/state').statePath(TMP)));
  assert.equal(s.ratchet, 0);
  assert.throws(() => execFileSync('node', [RUN, 'nope'], { encoding: 'utf8' }));
});
