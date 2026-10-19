'use strict';
// ratchet/lib/commands.js — /ratchet command seam: status + reset.
'use strict';

const state = require('./state');
const { render } = require('./panel');

const COMMANDS = [
  {
    name: 'ratchet:status',
    description: 'Show ratchet level, block count, recent events',
  },
  {
    name: 'ratchet:reset',
    description: 'Reset ratchet state for the current directory',
  },
];

function dispatch(name, cwd) {
  switch (name) {
    case 'ratchet:status':
      return render(cwd);
    case 'ratchet:reset':
      state.reset(cwd);
      return 'ratchet state reset';
    default:
      return `unknown command: ${name}`;
  }
}

// registerCommands(api) — api = { addCommand({ name, description, run }) }.
function registerCommands(api) {
  for (const c of COMMANDS) {
    api.addCommand({ ...c, run: (cwd) => dispatch(c.name, cwd) });
  }
}

module.exports = { COMMANDS, dispatch, registerCommands };
