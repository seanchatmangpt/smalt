/**
 * Append-only hash-chained session ledger + guardedFetch (lane WS-4).
 *
 * Zero-actuation enforcement at the network boundary: any request whose
 * method+URL matches a mutation pattern (lib/copilot/verb-gate.ts) makes NO
 * network call — a typed refusal is appended to the ledger and returned.
 *
 * Ledger contract for lane WS-11:
 *   appendLedger(entry) -> LedgerEntry   (hash chain: entry.prevHash = tail.hash)
 *   getLedgerSnapshot() -> LedgerSnapshot { entries, tailHash, length, intact }
 *   verifyLedgerChain(snapshot) -> boolean
 *   resetLedger() -> void   (test isolation only)
 */

import { isMutation } from './verb-gate';
import { makeRefusal, type TypedRefusal } from './typed-refusal';

export interface LedgerEntry {
  seq: number;
  ts: number;
  kind: 'refusal' | 'read' | 'event';
  /** Refusals carry the full typed refusal; reads carry verb+url summary. */
  refusal?: TypedRefusal;
  verb: string;
  url: string;
  prevHash: string;
  hash: string;
}

export interface LedgerSnapshot {
  entries: readonly LedgerEntry[];
  tailHash: string;
  length: number;
  /** True when the hash chain verifies end-to-end. */
  intact: boolean;
}

const GENESIS = 'GENESIS';

const entries: LedgerEntry[] = [];

/** Deterministic FNV-1a 64-bit chain hash (integrity chaining, not secrecy). */
function chainHash(input: string): string {
  let h = 0xcbf29ce484222325n;
  const prime = 0x100000001b3n;
  for (let i = 0; i < input.length; i++) {
    h ^= BigInt(input.charCodeAt(i));
    h = (h * prime) & 0xffffffffffffffffn;
  }
  return h.toString(16).padStart(16, '0');
}

function computeHash(e: Omit<LedgerEntry, 'hash'>): string {
  return chainHash(
    [e.seq, e.ts, e.kind, e.verb, e.url, e.prevHash, e.refusal?.reason ?? ''].join('|'),
  );
}

export function appendLedger(
  e: Omit<LedgerEntry, 'seq' | 'prevHash' | 'hash'>,
): LedgerEntry {
  const prevHash = entries.length === 0 ? GENESIS : entries[entries.length - 1].hash;
  const seq = entries.length;
  const base = { ...e, seq, prevHash };
  const entry: LedgerEntry = { ...base, hash: computeHash(base) };
  entries.push(entry);
  return entry;
}

export function appendRefusal(refusal: TypedRefusal, verb: string, url: string): LedgerEntry {
  return appendLedger({ ts: refusal.ts, kind: 'refusal', refusal, verb, url });
}

export function getLedgerSnapshot(): LedgerSnapshot {
  let prev = GENESIS;
  let intact = true;
  for (const e of entries) {
    if (e.prevHash !== prev || e.hash !== computeHash({ ...e })) {
      intact = false;
      break;
    }
    prev = e.hash;
  }
  return {
    entries: [...entries],
    tailHash: entries.length === 0 ? GENESIS : entries[entries.length - 1].hash,
    length: entries.length,
    intact,
  };
}

export function verifyLedgerChain(snapshot: LedgerSnapshot): boolean {
  let prev = GENESIS;
  for (const e of snapshot.entries) {
    if (e.prevHash !== prev) return false;
    if (e.hash !== computeHash({ ...e })) return false;
    prev = e.hash;
  }
  return true;
}

export function resetLedger(): void {
  entries.length = 0;
}

export const GENESIS_HASH = GENESIS;

export interface GuardedFetchResult {
  /** False when refused: no network call was made. */
  ok: boolean;
  refusal?: TypedRefusal;
  response?: Response;
}

/**
 * Fetch wrapper enforcing zero actuation. Mutation-shaped requests never
 * reach the network; the typed refusal is both returned and ledgered.
 * Read verbs (GET /subscriptions, GET metrics, "..." + "/read") pass through to
 * the underlying fetch.
 */
export async function guardedFetch(
  input: RequestInfo | URL,
  init?: RequestInit,
): Promise<GuardedFetchResult> {
  const method = (init?.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase();
  const url = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;

  if (isMutation(method, url)) {
    const refusal = makeRefusal('ZERO_ACTUATION', method, url);
    appendRefusal(refusal, method, url);
    return { ok: false, refusal };
  }

  const response = await fetch(input, init);
  appendLedger({ ts: Date.now(), kind: 'read', verb: method, url });
  return { ok: true, response };
}
