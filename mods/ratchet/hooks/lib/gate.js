'use strict';
// ratchet/lib/gate.js — tool.call gate (R7 seam): PreToolUse deny for hand-editing
// generated artifacts, force-push, and rm -rf of the checkout root.
'use strict';

const state = require('./state');

// Repo law (CLAUDE.md): generated artifacts are never hand-edited.
const GENERATED = [
  'docs/ERROR_CODES.md',
  'docs/jira/v*/RECEIPTS.md',
  'docs/jira/v*/receipts/INDEX.md',
  'docs/jira/v*/BENCH_RESULTS.md',
  'docs/jira/v*/SDK_MATRIX.md',
];

const DENY_PATTERNS = [
  { re: /\brm\s+-rf\s+\/(?:\s|$)/, why: 'rm -rf of filesystem root' },
  { re: /\bgit\s+push\b[^|]*--force\b[^|]*\bmain\b/, why: 'force-push to main' },
];

function gate(toolName, input, cwd) {
  const reason = evaluate(toolName, input, cwd);
  if (reason) {
    state.record(cwd, 'gate-block', reason);
    return { ok: false, reason };
  }
  return { ok: true, reason: null };
}

function evaluate(toolName, input, cwd) {
  if (toolName === 'Bash') {
    const cmd = String((input && input.command) || '');
    for (const p of DENY_PATTERNS) {
      p.re.lastIndex = 0;
      if (p.re.test(cmd)) return `blocked: ${p.why}`;
    }
  }
  if ((toolName === 'Edit' || toolName === 'Write') && input && input.file_path) {
    const fp = String(input.file_path);
    for (const g of GENERATED) {
      if (globToRe(g).test(fp)) {
        return `blocked: hand-edit of generated artifact ${g} (regenerate, don't patch)`;
      }
    }
  }
  return null;
}

function globToRe(glob) {
  const esc = glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*');
  return new RegExp(`(?:^|/)${esc}$`);
}

// registerGate(api) — api = { onGate(fn) }; fn(toolName, input, cwd) -> {ok, reason}.
function registerGate(api) {
  api.onGate((toolName, input, cwd) => gate(toolName, input, cwd));
}

module.exports = { gate, evaluate, registerGate, GENERATED, DENY_PATTERNS };
