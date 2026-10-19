'use strict';
// ratchet/lib/state.js — shared state store for all ratchet hooks.
// State file lives in temp, keyed by cwd, so concurrent sessions don't fight.
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const EMPTY = Object.freeze({ ratchet: 0, blocks: 0, events: [] });

function statePath(cwd) {
  const key = path.join(cwd || process.cwd())
    .replace(/[^A-Za-z0-9._-]+/g, '_');
  return path.join(os.tmpdir(), `ratchet-state-${key}.json`);
}

function load(cwd) {
  try {
    return { ...EMPTY, ...JSON.parse(fs.readFileSync(statePath(cwd), 'utf8')) };
  } catch {
    return { ...EMPTY, events: [] };
  }
}

function save(cwd, state) {
  const p = statePath(cwd);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(state, null, 2));
  return p;
}

function record(cwd, kind, detail) {
  const s = load(cwd);
  s.events = [...s.events.slice(-99), { t: new Date().toISOString(), kind, detail }];
  if (kind === 'gate-block') s.blocks += 1;
  s.ratchet += 1;
  save(cwd, s);
  return s;
}

function reset(cwd) {
  save(cwd, { ...EMPTY, events: [] });
  return { ...EMPTY };
}

module.exports = { statePath, load, save, record, reset, EMPTY };
