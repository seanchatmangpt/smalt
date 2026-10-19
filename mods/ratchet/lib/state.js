// Ratchet state module — derives AZB ticket ratchet state from disk.
// Pure derivation over: TICKETS.md (ticket ids, Lane, Deps) + receipts/ (azb-*.md)
// + ratchet-state.json (lastTick / lastDispatch / dispatchedTickets / mode).
// No sleeps, no network. Only node:fs + node:path. ESM.

import fs from 'node:fs';
import path from 'node:path';

const AZB_ID_RE = /^###\s+(AZB-\d{2})\b/;
// Fields are inline on one bullet: `- **Q** CREATE · **Lane** planes · **Deps** AZB-04`
const LANE_RE = /\*\*Lane\*\*\s+([^\n·]+?)(?:\s+·\s|\s*$)/;
const DEPS_RE = /\*\*Deps\*\*\s+(.+)$/;

// DEPS "—" or "none" or empty => no deps. Supports "AZB-05..08" ranges and comma lists.
export function parseDeps(raw) {
  const s = (raw || '').trim();
  if (!s || s === '—' || /^none$/i.test(s)) return [];
  const out = [];
  for (const partRaw of s.split(',')) {
    const part = partRaw.trim();
    const range = part.match(/^(AZB-\d{2})\.\.(\d{2})$/);
    if (range) {
      const lo = parseInt(range[1].slice(4), 10);
      const hi = parseInt(range[2], 10);
      for (let n = lo; n <= hi; n++) out.push(`AZB-${String(n).padStart(2, '0')}`);
    } else {
      const single = part.match(/^AZB-\d{2}$/);
      if (single) out.push(part);
    }
  }
  return out;
}

// Parse TICKETS.md -> [{ id, lane, deps }]
export function parseTickets(md) {
  const tickets = [];
  let cur = null;
  for (const line of md.split('\n')) {
    const head = line.match(AZB_ID_RE);
    if (head) {
      if (cur) tickets.push(cur);
      cur = { id: head[1], lane: null, deps: [] };
      continue;
    }
    if (cur) {
      const lane = line.match(LANE_RE);
      if (lane) cur.lane = lane[1].trim();
      const deps = line.match(DEPS_RE);
      if (deps) cur.deps = parseDeps(deps[1]);
    }
  }
  if (cur) tickets.push(cur);
  return tickets;
}

// Receipt filenames matching azb-<NN>-<slug>.md (azb-11b-* does NOT match: not a ticket receipt).
export function ticketReceiptMap(filenames) {
  const map = new Map(); // 'AZB-11' -> 'azb-11-isolation-court.md'
  for (const name of filenames) {
    const m = name.match(/^azb-(\d{2})-[^.]*\.md$/);
    if (m) {
      map.set(`AZB-${m[1]}`, name);
    }
  }
  return map;
}

// Landed = receipt exists for the ticket's own azb-NN- prefix.
export function computeState(tickets, receiptMap) {
  const all = tickets.map((t) => {
    const receipt = receiptMap.get(t.id) || null;
    const landed = receipt !== null;
    const depsSatisfied =
      t.deps.length === 0 || t.deps.every((d) => receiptMap.has(d));
    return {
      id: t.id,
      lane: t.lane,
      deps: t.deps,
      status: landed ? 'LANDED' : 'OPEN',
      receipt,
      depsSatisfied,
    };
  });

  const landed = all.filter((t) => t.status === 'LANDED');
  const open = all.filter((t) => t.status === 'OPEN');
  const next = open.find((t) => t.depsSatisfied) || null;

  return {
    ticketsLanded: landed.map((t) => t.id),
    ticketsOpen: open.map((t) => ({
      id: t.id,
      lane: t.lane,
      deps: t.deps,
      depsSatisfied: t.depsSatisfied,
    })),
    receiptsTotal: receiptMap.size,
    nextTicket: next ? next.id : null,
    nextLane: next ? next.lane : null,
    all: Object.fromEntries(all.map((t) => [t.id, t])),
  };
}

export function readState(p) {
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch {
    return { lastTick: null, lastDispatch: null, dispatchedTickets: [], mode: null };
  }
}

export function writeState(p, state) {
  fs.writeFileSync(p, JSON.stringify(state, null, 2) + '\n');
}

// Convenience: full from-disk derivation against the live repo layout.
export function stateFromRepo(repoRoot) {
  const ticketsPath = path.join(
    repoRoot,
    'docs/jira/v26.10.18/azsim-burn/TICKETS.md',
  );
  const receiptsDir = path.join(repoRoot, 'docs/jira/v26.10.18/receipts');
  const tickets = parseTickets(fs.readFileSync(ticketsPath, 'utf8'));
  const files = fs.readdirSync(receiptsDir);
  const receiptMap = ticketReceiptMap(files);
  return { state: computeState(tickets, receiptMap), ticketCount: tickets.length };
}
