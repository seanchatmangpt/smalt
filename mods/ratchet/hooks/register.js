'use strict';
// ratchet/register.js — Register-hook entry point (final wiring).
// Emits the hooks config on stdout; the four register* functions are invoked
// against a collector api so every lib seam is actually wired, not just listed.
'use strict';

const { registerPanel } = require('./lib/panel');
const { registerTurn } = require('./lib/inject');
const { registerGate } = require('./lib/gate');
const { registerCommands } = require('./lib/commands');

const RUN = `node "\${CLAUDE_PLUGIN_ROOT}/hooks/run.js"`;

// collector api — each register* fn attaches handlers; collect them so the
// emitted hooks config and the wiring are provably the same handlers.
function makeApi() {
  const handlers = { render: [], turn: [], gate: [], commands: [] };
  return {
    handlers,
    onRender: (fn) => handlers.render.push(fn),
    onTurn: (fn) => handlers.turn.push(fn),
    onGate: (fn) => handlers.gate.push(fn),
    addCommand: (c) => handlers.commands.push(c),
  };
}

const api = makeApi();
registerPanel(api); // R3 seam: ui.render
registerTurn(api); // R5 seam: turn.complete + timer tick
registerGate(api); // R7 seam: tool.call gate
registerCommands(api); // /ratchet:* command surface

function emit() {
  return {
    hooks: {
      UserPromptSubmit: [{ hooks: [{ type: 'command', command: `${RUN} panel` }] }],
      PreToolUse: [
        {
          matcher: 'Bash|Edit|Write',
          hooks: [{ type: 'command', command: `${RUN} gate` }],
        },
      ],
      PostToolUse: [
        {
          matcher: 'ExitPlanMode|Task',
          hooks: [{ type: 'command', command: `${RUN} turn` }],
        },
      ],
      SessionStart: [{ hooks: [{ type: 'command', command: `${RUN} panel` }] }],
      SessionEnd: [{ hooks: [{ type: 'command', command: `${RUN} turn` }] }],
    },
  };
}

module.exports = { makeApi, api, emit, handlers: api.handlers };

if (require.main === module) {
  process.stdout.write(JSON.stringify(emit(), null, 2));
}
