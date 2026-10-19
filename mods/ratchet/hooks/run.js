'use strict';
// ratchet/run.js — one adapter, four kinds: panel | gate | turn | commands.
// Reads the hook payload JSON on stdin, dispatches to the lib modules, and
// emits Claude Code hook-protocol JSON on stdout where a decision exists.
'use strict';

const { render } = require('./lib/panel');
const { gate } = require('./lib/gate');
const { turnComplete, tick } = require('./lib/inject');
const { dispatch } = require('./lib/commands');

function readStdin() {
  try {
    return JSON.parse(require('fs').readFileSync(0, 'utf8') || '{}');
  } catch {
    return {};
  }
}

function main() {
  const kind = process.argv[2] || '';
  const payload = readStdin();
  const cwd = payload.cwd || process.cwd();

  if (kind === 'panel') {
    const note = tick(cwd);
    const lines = render(cwd);
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'UserPromptSubmit',
          additionalContext: note ? `${lines}\n${note}` : lines,
        },
      })
    );
    return 0;
  }

  if (kind === 'gate') {
    const r = gate(payload.tool_name, payload.tool_input || {}, cwd);
    if (r.ok) return 0; // silent allow
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: r.reason,
          additionalContext: r.reason,
        },
      })
    );
    return 0;
  }

  if (kind === 'turn') {
    turnComplete(cwd, payload.tool_name || payload.reason || 'session-end');
    return 0;
  }

  if (kind === 'commands') {
    process.stdout.write(String(dispatch(payload.command || '', cwd)));
    return 0;
  }

  process.stderr.write(`ratchet/run.js: unknown kind '${kind}'\n`);
  return 2;
}

process.exit(main());
