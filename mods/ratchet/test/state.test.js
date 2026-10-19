'use strict';
// R9 lane — lib/state.js tests against the REAL repo files (Chicago: real
// collaborators; the fixtures here are the repo's own TICKETS.md + receipts/).
// Run: node --test /Users/sac/smalt/mods/ratchet/test/

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const REPO = '/Users/sac/smalt';
const TICKETS = path.join(REPO, 'docs/jira/v26.10.18/azsim-burn/TICKETS.md');
const RECEIPTS = path.join(REPO, 'docs/jira/v26.10.18/receipts');
const state = () => import('../lib/state.js');

test('parseTickets on the real TICKETS.md -> 24 tickets with lanes and parsed deps', async () => {
  const fs = require('node:fs');
  const { parseTickets } = await state();
  const tickets = parseTickets(fs.readFileSync(TICKETS, 'utf8'));
  assert.equal(tickets.length, 24);
  for (const t of tickets) {
    assert.match(t.id, /^AZB-\d{2}$/);
    assert.equal(typeof t.lane, 'string');
    assert.ok(Array.isArray(t.deps));
  }
  // spot-check the real DAG: AZB-02 depends on AZB-01; AZB-22 carries deps
  const byId = new Map(tickets.map((t) => [t.id, t]));
  assert.deepEqual(byId.get('AZB-02').deps, ['AZB-01']);
  assert.ok(byId.get('AZB-22').deps.length >= 2);
});

test('receipts glob against the real receipts dir -> current landed count', async () => {
  const fs = require('node:fs');
  const { stateFromRepo } = await state();
  const { state: s, ticketCount } = stateFromRepo(REPO);
  assert.equal(ticketCount, 24);

  // independent glob: azb-NN-<slug>.md (two-digit, one dot only)
  const real = fs
    .readdirSync(RECEIPTS)
    .filter((f) => /^azb-\d{2}-[^.]*\.md$/.test(f));
  assert.equal(s.receiptsTotal, real.length);
  assert.ok(s.receiptsTotal > 0);

  // every landed ticket maps to a real file on disk
  for (const id of s.ticketsLanded) {
    const f = s.all[id].receipt;
    assert.equal(fs.existsSync(path.join(RECEIPTS, f)), true, f);
  }
  // azb-11b is NOT a ticket receipt and must not map onto AZB-11
  assert.ok(!/azb-11b/.test(s.all['AZB-11'].receipt || ''));
});

test('DAG priority: nextTicket is a deps-satisfied OPEN ticket (first in file order)', async () => {
  const fs = require('node:fs');
  const { parseTickets, ticketReceiptMap, computeState } = await state();
  const tickets = parseTickets(fs.readFileSync(TICKETS, 'utf8'));
  const map = ticketReceiptMap(fs.readdirSync(RECEIPTS));
  const s = computeState(tickets, map);

  assert.notEqual(s.nextTicket, null);
  const next = s.all[s.nextTicket];
  assert.equal(next.status, 'OPEN');
  assert.equal(next.depsSatisfied, true);
  for (const d of next.deps) assert.ok(map.has(d), `dep ${d} must be landed`);
  // it really is the FIRST such open ticket in TICKETS.md order
  const firstReady = tickets
    .filter((t) => !map.has(t.id) && t.deps.every((d) => map.has(d)))
    .map((t) => t.id);
  assert.ok(firstReady.length > 0);
  assert.equal(s.nextTicket, firstReady[0]);

  // receipt-map sensitivity: deps count as satisfied only when a receipt for
  // that exact azb-NN- prefix exists (synthetic map over the real parser).
  const azb02 = s.all['AZB-02'];
  assert.equal(azb02.depsSatisfied, map.has('AZB-01'));
  const without = computeState(tickets, new Map([...map].filter(([k]) => k !== 'AZB-01')));
  assert.equal(without.all['AZB-02'].depsSatisfied, false, 'AZB-02 needs AZB-01');
  assert.notEqual(without.all['AZB-02'].depsSatisfied, undefined);
});
