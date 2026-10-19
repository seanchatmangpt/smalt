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
  // nothing shell-significant survives from the free text
  assert.ok(![`$`, '`', ';', '|', '&', '>', '<', '\\', '"', "'"].some((c) => text.includes(c)),
    'prompt must be free of shell-significant characters');
  assert.ok(!/rm -rf|curl\(|curl\$| \|\||&&/.test(text), 'raw free text must not pass through as prose');
  // the prompt is EXACTLY the bounded template: ticket id + [a-z0-9-]{1,40} slug only
  const tpl = /^AZB ratchet: dispatch an agent for AZB-\d{2} per docs\/jira\/v26\.10\.18\/azsim-burn\/TICKETS\.md — receipt to docs\/jira\/v26\.10\.18\/receipts\/azb-\d{2}-[a-z0-9-]{1,40}\.md$/;
  assert.match(text, tpl, 'prompt must be the exact bounded template');
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

test('submit fault: the reserved dedup window is released, error surfaces typed', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ratchet-inject-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const statePath = path.join(dir, 'inject-state.json');
  const api = {
    fs: {
      read: async (fp) => fs.readFileSync(fp === STATE_PATH ? statePath : fp, 'utf8'),
      write: async (fp, data) => fs.writeFileSync(fp === STATE_PATH ? statePath : fp, data),
    },
    prompt: {
      submit: async () => { throw new Error('session busy (simulated fault)'); },
    },
  };
  const m = await inject();
  m.initInject(api);
  await assert.rejects(() => m.injectDispatch('AZB-19 overlap'), /session busy/);
  // the reservation must have been rolled back to the pre-call state
  const persisted = readPersisted(statePath);
  assert.equal(persisted.lastInjectAt, 0, 'window released after submit fault');
  assert.equal(persisted.dispatchLock, false);
});
