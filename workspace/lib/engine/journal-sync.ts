/**
 * ATH-2 local journal — IndexedDB-backed write-ahead log + batch sync engine.
 *
 * Domain-blind: this module moves opaque frames and integer cursors. Store
 * names per the ATH wire contract: db `smalt_local_ledger`, object store
 * `wal_segments` (keyPath `seqId`), plus a `sync_cursor` store holding the
 * highest server-acknowledged seqId (single record, key `"cursor"`).
 *
 * Networking rides smaltFetch exclusively (air-gap law). The batch contract
 * with the server lane (ATH-1) is byte-exact:
 *
 *   request : concatenated encoded frames (41-byte header + payload each)
 *   response: { lastSeq: number, receiptToken: string }
 *
 * and a successful response advances the ack cursor to `lastSeq`.
 */

import { encodeFrame, type Frame, type CodecError } from "./codec";
import { snapbackWithStore, type SnapbackPlan } from "./snapback";
import { verifyReceipt } from "./receipt";
import { SMALT_EGRESS, smaltFetch } from "../smalt";
import { withWalLease, type WalLeaseError, type LeaseMode, type PeerGuard } from "./tab-lease";

export const LEDGER_DB = "smalt_local_ledger";
export const SEGMENT_STORE = "wal_segments";
export const CURSOR_STORE = "sync_cursor";
export const SYNC_PATH = "/sync/journal/batch";

const CURSOR_KEY = "cursor";
/** EXP1C W3: persisted per-origin client identity (random u64, sync_cursor store). */
const CLIENT_ID_KEY = "clientId";

/**
 * EXP1C W3: the page's persistent client identity. Every console used to
 * append with hardcoded clientId 0n — two consoles collided on (0, seq) and
 * the server's per-client head tracking refused/snapbacked. Mint a random
 * u64 once, persist it in the `sync_cursor` store, reuse forever after.
 */
export async function ensureClientId(): Promise<JournalResult<bigint>> {
  // WSKEP-R1 (BK-WSKEP F1): the whole read-mint-write runs through one FIFO
  // turnstile (pattern 3 idiom) so two concurrent first-boot callers in one
  // page can never both observe the empty store; the mint+persist runs in a
  // single readwrite transaction (real-IDB store-scope atomicity) so the
  // loser of a cross-tab race reads the winner's committed identity instead
  // of last-writer-wins over it.
  return clientIdQueue.run(async () => {
    try {
      const db = await openDb();
      const tx = db.transaction([CURSOR_STORE], "readwrite");
      const store = tx.objectStore(CURSOR_STORE);
      const existing = (await req(store.get(CLIENT_ID_KEY))) as string | undefined;
      if (typeof existing === "string" && /^[0-9]+$/.test(existing)) {
        await txDone(tx);
        return { ok: true, value: BigInt(existing) };
      }
      // Mint a random nonzero u64 (crypto when present, Math.random fallback).
      let minted = 0n;
      while (minted === 0n) {
        const buf = new Uint8Array(8);
        const c = (globalThis as { crypto?: Crypto }).crypto;
        if (c && typeof c.getRandomValues === "function") {
          c.getRandomValues(buf);
        } else {
          for (let i = 0; i < 8; i++) buf[i] = Math.floor(Math.random() * 256);
        }
        minted = 0n;
        for (const b of buf) minted = (minted << 8n) | BigInt(b);
      }
      store.put(minted.toString(), CLIENT_ID_KEY);
      await txDone(tx);
      return { ok: true, value: minted };
    } catch (e) {
      return { ok: false, error: storeFailure(e) };
    }
  });
}

// BK-83 AUTH-SEAM (landed from the court's disclosed delta): court- or
// page-set bearer token for the flushSync smaltFetch call. Empty (default)
// sends a tokenless request — enforce mode answers the typed 401 challenge
// (KD-15 shape) and the flush refuses SYNC_HTTP/401.
let _syncAuthHeader = "";
export function setSyncAuthHeader(h: string) {
  _syncAuthHeader = h;
}
function syncAuthHeader(): string {
  return _syncAuthHeader;
}

/** A stored journal entry — the encoded frame plus its ack standing. */
export interface Segment {
  seqId: number;
  clientId: string;
  ts: number;
  op: number;
  payload: ArrayBuffer;
  frame: ArrayBuffer;
  acked: boolean;
}

export type JournalError =
  | { code: "INDEXEDDB_UNAVAILABLE" }
  | { code: "STORE_FAILURE"; detail: string }
  | { code: "SYNC_HTTP"; status: number }
  | { code: "SYNC_REFUSED"; detail: string }
  | { code: "PEER_TAB_ACTIVE"; peers: string[] }
  | { code: "SYNC_REFUSED_BY_SERVER"; detail: string; serverHeadSeq: number; purged: number };

export type JournalResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: JournalError };

function idb(): IDBFactory | undefined {
  return (globalThis as { indexedDB?: IDBFactory }).indexedDB;
}

function req<T>(r: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}

function txDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

let dbPromise: Promise<IDBDatabase> | null = null;

function openDb(): Promise<IDBDatabase> {
  const f = idb();
  if (!f) return Promise.reject(err({ code: "INDEXEDDB_UNAVAILABLE" }));
  if (!dbPromise) {
    const p = new Promise<IDBDatabase>((resolve, reject) => {
      const open = f.open(LEDGER_DB, 1);
      open.onupgradeneeded = () => {
        const db = open.result;
        if (!db.objectStoreNames.contains(SEGMENT_STORE)) {
          db.createObjectStore(SEGMENT_STORE, { keyPath: "seqId" });
        }
        if (!db.objectStoreNames.contains(CURSOR_STORE)) {
          db.createObjectStore(CURSOR_STORE);
        }
      };
      // EXP1C W5: a version upgrade blocked by an older tab hung the open
      // promise forever — refuse typed instead of hanging silently.
      open.onblocked = () =>
        reject(
          err({
            code: "STORE_FAILURE",
            detail: "indexedDB open blocked (another tab holds an older version)",
          }),
        );
      open.onsuccess = () => resolve(open.result);
      open.onerror = () => reject(err({ code: "STORE_FAILURE", detail: String(open.error) }));
    });
    // EXP1C W5: never negative-cache a failed open — one transient IDB
    // failure used to brick the journal for the page lifetime (every later
    // op refused STORE_FAILURE with no retry path). Reset so the next call
    // retries the open.
    p.catch(() => {
      dbPromise = null;
    });
    dbPromise = p;
  }
  return dbPromise;
}

function err(e: JournalError): JournalError {
  return e;
}

function storeFailure(e: unknown): JournalError {
  const code = (e as { code?: string })?.code;
  // Already-typed JournalErrors (openDb's blocked/failed open) pass through
  // with their detail intact — String()-ing a typed error obliterates it.
  if (code === "INDEXEDDB_UNAVAILABLE") return { code: "INDEXEDDB_UNAVAILABLE" };
  if (code === "STORE_FAILURE" && typeof (e as { detail?: unknown }).detail === "string") {
    return e as JournalError;
  }
  return { code: "STORE_FAILURE", detail: String(e).slice(0, 200) };
}

// --- pattern 3 (Monotonic Turnstile): serialized appends --------------------

/**
 * FIFO promise queue: every task starts only after the previous one settles.
 * The 50-burst contract (contiguous seq, no interleaving) is enforced here,
 * in one place, independent of caller discipline.
 */
export class AppendQueue {
  private tail: Promise<unknown> = Promise.resolve();

  run<T>(task: () => Promise<T>): Promise<T> {
    const started = this.tail.then(task, task);
    this.tail = started.catch(() => undefined);
    return started;
  }
}

/** Module-level turnstile — all appends funnel through this instance. */
export const appendQueue = new AppendQueue();

/** WSKEP-R1 (BK-WSKEP F1): FIFO turnstile for the clientId read-mint-write. */
const clientIdQueue = new AppendQueue();

// --- pure hydration math (pattern 5; node-court-testable) -------------------

/**
 * Pure: next free seqId from a segment set — max(seqId) + 1, 0 when empty.
 * (hydrate() and appendLocal both express the turnstile through this.)
 */
export function nextSeqFromSegments(segments: { seqId: number }[]): number {
  return segments.reduce((m, s) => Math.max(m, s.seqId), 0) + 1;
}

/** Pure: un-acked count above the ack floor. */
export function countUnsynced(
  segments: { seqId: number }[],
  ackCursor: number,
): number {
  return segments.filter((s) => s.seqId > ackCursor).length;
}

export interface Hydrated {
  /** Highest journaled seqId (0 when the journal is fresh). */
  currentSeq: number;
  /** Segments above the ack cursor. */
  unsyncedCount: number;
  /**
   * Stored frame bytes, ascending by seqId — replayed into the running
   * accumulator by the caller to rebuild the merkle horizon. Choice
   * documented: rebuild-from-frames (exact chain, O(n) on init) over
   * persisting the accumulator root (which would trust a stored digest the
   * frames no longer prove).
   */
  frames: Uint8Array[];
  /**
   * EXP1C W4: the same frames carried WITH their seqIds, ascending. Receipt
   * verification slices by seqId, never array index — an array-index slice
   * mapped the wrong frames into the chain on any mid-ledger gap.
   */
  entries: { seqId: number; frame: Uint8Array }[];
}

/**
 * Pattern 5 (Cold Ash Rehydration): restore the seq/merkle horizon from
 * IndexedDB before the page reports READY_STANDALONE. Returns the full
 * stored-frame list so the caller rebuilds the accumulator by replay; the
 * pure math (next-seq, unsynced count) lives in the exported helpers above.
 */
export async function hydrate(): Promise<JournalResult<Hydrated>> {
  try {
    const db = await openDb();
    const tx = db.transaction([SEGMENT_STORE], "readonly");
    const all = (await req(tx.objectStore(SEGMENT_STORE).getAll())) as Segment[];
    const sorted = all.slice().sort((a, b) => a.seqId - b.seqId);
    const cur = await syncedCursor();
    const floor = cur.ok ? cur.value : 0;
    return {
      ok: true,
      value: {
        currentSeq: nextSeqFromSegments(sorted) - 1,
        unsyncedCount: countUnsynced(sorted, floor),
        frames: sorted.map((s) => new Uint8Array(s.frame)),
        entries: sorted.map((s) => ({ seqId: s.seqId, frame: new Uint8Array(s.frame) })),
      },
    };
  } catch (e) {
    return { ok: false, error: storeFailure(e) };
  }
}

/** Highest server-acknowledged seqId (0 when the journal is fresh). */
export async function syncedCursor(): Promise<JournalResult<number>> {
  try {
    const db = await openDb();
    const tx = db.transaction([CURSOR_STORE], "readonly");
    const v = (await req(tx.objectStore(CURSOR_STORE).get(CURSOR_KEY))) as number | undefined;
    return { ok: true, value: typeof v === "number" ? v : 0 };
  } catch (e) {
    return { ok: false, error: storeFailure(e) };
  }
}

/** Next free seqId (max known seqId + 1). */
export async function nextSeqId(): Promise<JournalResult<number>> {
  try {
    const db = await openDb();
    const tx = db.transaction([SEGMENT_STORE], "readonly");
    const cursor = await req(tx.objectStore(SEGMENT_STORE).openCursor(null, "prev"));
    const lastNum = cursor ? (cursor as IDBCursor).key as number : 0;
    return { ok: true, value: (typeof lastNum === "number" ? lastNum : 0) + 1 };
  } catch (e) {
    return { ok: false, error: storeFailure(e) };
  }
}

/** Un-acked segments, ascending by seqId. */
export async function unacked(): Promise<JournalResult<Segment[]>> {
  try {
    const db = await openDb();
    const tx = db.transaction([SEGMENT_STORE], "readonly");
    const all = (await req(tx.objectStore(SEGMENT_STORE).getAll())) as Segment[];
    const cur = await syncedCursor();
    const floor = cur.ok ? cur.value : 0;
    return { ok: true, value: all.filter((s) => s.seqId > floor).sort((a, b) => a.seqId - b.seqId) };
  } catch (e) {
    return { ok: false, error: storeFailure(e) };
  }
}

/**
 * Append one op/payload pair as the next segment; frame bytes are encoded
 * here. All calls serialize through the module turnstile (pattern 3), so
 * concurrent callers observe contiguous seqIds.
 *
 * SPOF-4.3: internal — mutates the ledger WITHOUT the master lease. The only
 * public append path is the lease-wrapped `appendLocal` below.
 */
function _appendLocal(
  clientId: bigint,
  op: number,
  payload: Uint8Array,
): Promise<JournalResult<Segment>> {
  return appendQueue.run(async () => {
    try {
      const db = await openDb();
      const tx = db.transaction([SEGMENT_STORE], "readwrite");
      const store = tx.objectStore(SEGMENT_STORE);
      const last = await req(store.openCursor(null, "prev"));
      const lastKey =
        last && typeof last === "object" && "key" in (last as object)
          ? (last as IDBCursor).key
          : undefined;
      const seq = (typeof lastKey === "number" ? lastKey : 0) + 1;
      const frame = encodeFrame(clientId, BigInt(seq), BigInt(Date.now()), op, payload);
      const segment: Segment = {
        seqId: seq,
        clientId: clientId.toString(),
        ts: Date.now(),
        op,
        payload: payload.slice().buffer,
        frame: frame.slice().buffer as ArrayBuffer,
        acked: false,
      };
      store.put(segment);
      await txDone(tx);
      return { ok: true, value: segment };
    } catch (e) {
      return { ok: false, error: storeFailure(e) };
    }
  });
}

/**
 * SPOF-4.3: internal — advances the ack cursor WITHOUT the master lease.
 * Runs only inside lease-holding callers (flushSync, snapback). EXP1C W8:
 * the dead public `markSynced`/`snapbackStoreOps` wrappers were deleted —
 * both re-requested the same-client Web Lock from inside a lease holder
 * (nested-lock deadlock class, witnessed live on Node 26) and had zero
 * callers.
 */
async function _markSynced(seq: number): Promise<JournalResult<number>> {
  try {
    const db = await openDb();
    const tx = db.transaction([CURSOR_STORE], "readwrite");
    tx.objectStore(CURSOR_STORE).put(seq, CURSOR_KEY);
    await txDone(tx);
    return { ok: true, value: seq };
  } catch (e) {
    return { ok: false, error: storeFailure(e) }
  }
}

export interface SyncReceipt {
  lastSeq: number;
  receiptToken: string;
  markedTo: number | null;
  /** P8: highest seqId actually acked by this flush (0 when nothing to send). */
  syncedSeq: number;
  /** P12: decoded receipt byte length (0 when no token). */
  receiptBytes: number;
  /** P12: receipt root matched the local leaf chain. */
  verified: boolean;
}

/**
 * P10 wiring: snapback store ops over the real IndexedDB journal.
 * Purges every un-acked segment, resets the ack cursor to the server head.
 */
/**
 * SPOF-4.3: internal — raw store ops over the journal WITHOUT the master
 * lease. The public `snapbackStoreOps` is lease-wrapped.
 */
function _snapbackStoreOps() {
  return {
    listUnacked: async () => {
      const b = await unacked();
      return b.ok ? b.value : [];
    },
    deleteSeqIds: async (seqIds: number[]) => {
      if (seqIds.length === 0) return 0;
      try {
        const db = await openDb();
        const tx = db.transaction([SEGMENT_STORE], "readwrite");
        const store = tx.objectStore(SEGMENT_STORE);
        const wanted = new Set(seqIds);
        // EXP1C W4: IDB store.delete never reports a miss — the old code
        // returned seqIds.length even when nothing was deleted. Get-then-
        // delete over one transaction: count only seqIds actually present.
        const all = (await req(store.getAll())) as Segment[];
        const present = all.map((s) => s.seqId).filter((id) => wanted.has(id));
        for (const id of present) store.delete(id);
        await txDone(tx);
        return present.length;
      } catch {
        return 0;
      }
    },
    setCursor: async (seq: number) => {
      // BK-83 repair (deadlock, finding 2): raw `_markSynced` — the caller
      // already holds the master WAL lease, and a nested same-client
      // `navigator.locks` request deadlocks under real Web Locks (witnessed
      // live on Node 26). EXP1C W8: the dead public wrappers are gone.
      await _markSynced(seq);
    },
  };
}

/**
 * P10 Elastic Snapback against the real journal: purge un-acked records and
 * reset the seq horizon to the server's canonical head. Returns the applied
 * plan, or a JournalError when the store refused.
 *
 * SPOF-4.3: internal (no lease of its own) — callers hold the lease; the
 * public lease-wrapped surface is `flushSync`.
 */
async function applySnapback(
  serverHeadSeq: number,
): Promise<JournalResult<SnapbackPlan & { purged: number }>> {
  try {
    // BK-83 repair (deadlock, finding 2): internal ops — applySnapback only
    // ever runs inside flushSync, which already holds the master WAL lease;
    // the lease-wrapped public `snapbackStoreOps()` would re-request the
    // same-client lock and deadlock under real Web Locks (witnessed live on
    // Node 26). SPOF-4.3 internal-ops design.
    const applied = await snapbackWithStore(_snapbackStoreOps(), serverHeadSeq);
    return { ok: true, value: applied };
  } catch (e) {
    return { ok: false, error: { code: "STORE_FAILURE", detail: String(e).slice(0, 200) } };
  }
}

/**
 * Flush every un-acked frame as one binary batch over smaltFetch; on a
 * `200` with `{lastSeq, receiptToken}` advance the ack cursor (P8) and
 * verify the receipt against the local leaf chain (P12). On a non-2xx whose
 * body is {refusal, serverHeadSeq} run the P10 snapback (purge un-acked,
 * reset cursor to serverHeadSeq) and refuse typed.
 */
async function _flushSync(opts: LeasedJournalOptions = {}): Promise<JournalResult<SyncReceipt>> {
  const batch = await unacked();
  if (!batch.ok) return batch;
  if (batch.value.length === 0) {
    return {
      ok: true,
      value: { lastSeq: 0, receiptToken: "", markedTo: null, syncedSeq: 0, receiptBytes: 0, verified: false },
    };
  }
  const parts = batch.value.map((s) => new Uint8Array(s.frame));
  const total = parts.reduce((n, p) => n + p.length, 0);
  const body = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    body.set(p, off);
    off += p.length;
  }
  try {
    const res = await smaltFetch(SMALT_EGRESS, SYNC_PATH, {
      method: "POST",
      headers: {
        "Content-Type": "application/octet-stream",
        // BK-83 AUTH-SEAM: the module-set bearer (setSyncAuthHeader / court)
        // or a per-call token rides the leased fetch path. Empty = tokenless,
        // which enforce mode answers with the typed 401 challenge.
        ...((opts.authHeader || syncAuthHeader())
          ? { Authorization: `Bearer ${opts.authHeader || syncAuthHeader()}` }
          : {}),
      },
      body,
    });
    if (!res.ok) {
      // P10: a refusal frame carries {refusal, serverHeadSeq} — snap back.
      type RefusalBody = { refusal?: unknown; serverHeadSeq?: unknown } | null;
      let refusal: RefusalBody = null;
      try {
        refusal = (await res.json()) as RefusalBody;
      } catch {
        refusal = null;
      }
      if (
        refusal &&
        typeof refusal.refusal === "string" &&
        typeof refusal.serverHeadSeq === "number"
      ) {
        const sb = await applySnapback(refusal.serverHeadSeq);
        return {
          ok: false,
          error: {
            code: "SYNC_REFUSED_BY_SERVER",
            detail: String(refusal.refusal).slice(0, 200),
            serverHeadSeq: refusal.serverHeadSeq,
            purged: sb.ok ? sb.value.purged : 0,
          },
        };
      }
      return { ok: false, error: { code: "SYNC_HTTP", status: res.status } };
    }
    const receipt = (await res.json()) as { lastSeq?: unknown; receiptToken?: unknown };
    if (typeof receipt.lastSeq !== "number" || typeof receipt.receiptToken !== "string") {
      return { ok: false, error: { code: "SYNC_REFUSED", detail: "malformed receipt body" } };
    }
    const lastSeq: number = receipt.lastSeq;
    // P12 (BK-83 finding 3, KD-165): the server seals the CUMULATIVE
    // per-client chain (leafCount covers every committed frame, not just
    // this batch), so verifying against only the flushed parts is
    // verified:false on ANY flush after the first. Verify against the FULL
    // local frame ledger, sliced to the acked horizon — the court's leg 6b
    // proves the security property directly.
    const ledger = await hydrate();
    // EXP1C W4: verify against the exact acked seqIds, never array index.
    // A mid-ledger gap (failed purge, partial snapback) used to slice the
    // WRONG frames into the receipt chain. A gap below the acked horizon is
    // a typed refusal, not a wrong-chain verify.
    let ledgerFrames: Uint8Array[] = [];
    if (ledger.ok) {
      const acked = ledger.value.entries.filter((s) => s.seqId <= lastSeq);
      const have = new Set(acked.map((s) => s.seqId));
      for (let i = 1; i <= lastSeq; i++) {
        if (!have.has(i)) {
          return {
            ok: false,
            error: {
              code: "SYNC_REFUSED",
              detail: `receipt chain gap: seqId ${i} missing below acked horizon lastSeq=${lastSeq}`,
            },
          };
        }
      }
      ledgerFrames = acked.map((s) => s.frame);
    }
    const vr = await verifyReceipt(ledgerFrames, receipt.receiptToken);
    const verified = vr.ok ? vr.verified : false;
    const marked = await _markSynced(receipt.lastSeq);
    return {
      ok: true,
      value: {
        lastSeq: receipt.lastSeq,
        receiptToken: receipt.receiptToken,
        markedTo: marked.ok ? marked.value : null,
        syncedSeq: marked.ok ? receipt.lastSeq : 0,
        receiptBytes: vr.ok ? vr.fields.byteLength : 0,
        verified,
      },
    };
  } catch (e) {
    return { ok: false, error: { code: "SYNC_REFUSED", detail: String(e).slice(0, 200) } };
  }
}

// --- SPOF-4.3: the lease-wrapped module surface (the only public path) ------

/**
 * Options threaded from the engine (or court) into the master WAL lease.
 */
export interface LeasedJournalOptions {
  /** SPOF-4.2: invoked after lease acquisition, BEFORE the body runs. */
  onAcquired?: (mode: LeaseMode) => Promise<void> | void;
  /** SPOF-4.1: peer-guard override (multi-engine hosts / courts). */
  peerGuard?: PeerGuard;
  /**
   * BK-83 AUTH-SEAM: per-call bearer token for the flushSync batch POST.
   * Overrides the module-level `setSyncAuthHeader` seam when set; empty
   * (default) = tokenless, which enforce mode answers with the typed 401.
   */
  authHeader?: string;
}

function leaseJournalError(e: WalLeaseError): JournalError {
  if (e.code === "PEER_TAB_ACTIVE") return { code: "PEER_TAB_ACTIVE", peers: e.peers };
  return { code: "STORE_FAILURE", detail: `WAL lease: ${e.code}` };
}

async function leased<U>(
  fn: () => Promise<JournalResult<U>>,
  opts: LeasedJournalOptions,
  extra?: { refuseFallbackWithPeers?: boolean },
): Promise<JournalResult<U>> {
  const r = await withWalLease(fn, {
    peerGuard: opts.peerGuard,
    onAcquired: opts.onAcquired,
    refuseFallbackWithPeers: extra?.refuseFallbackWithPeers,
  });
  return r.ok ? r.value : { ok: false, error: leaseJournalError(r.error) };
}

/**
 * Append one op/payload pair under the master WAL lease (SPOF-4.3: this is
 * the ONLY public append path). In fallback mode (no Web Locks) a live peer
 * tab refuses the append typed (`PEER_TAB_ACTIVE`) instead of double-minting
 * seqIds (SPOF-4.1); a genuinely single-tab fallback proceeds, degraded.
 */
export function appendLocal(
  clientId: bigint,
  op: number,
  payload: Uint8Array,
  opts: LeasedJournalOptions = {},
): Promise<JournalResult<Segment>> {
  return leased(() => _appendLocal(clientId, op, payload), opts, {
    refuseFallbackWithPeers: true,
  });
}

/**
 * Flush every un-acked frame as one binary batch — the drain holds the
 * master WAL lease (SPOF-4.3: this is the ONLY public flush path).
 */
export function flushSync(
  opts: LeasedJournalOptions = {},
): Promise<JournalResult<SyncReceipt>> {
  return leased(() => _flushSync(opts), opts);
}

// --- SPOF-4.2: rehydrate-on-promotion (pure math, node-court-testable) ------

/**
 * Pure: does a fresh look at the store disagree with the running snapshot's
 * horizon? True when the store holds a seqId the snapshot has never seen —
 * exactly the survivor-tab state after a master tab dies mid-append.
 */
export function needsRehydrate(currentSeq: number, storeMaxSeq: number): boolean {
  return storeMaxSeq > currentSeq;
}

/** Pure: the snapshot patch implied by a full hydration at `ackCursor`. */
export function rehydratePlan(
  h: {
    currentSeq: number;
    unsyncedCount: number;
    frames: Uint8Array[];
    entries?: { seqId: number }[];
  },
  ackCursor: number,
): { currentSeq: number; unsyncedCount: number; ackedTo: number; frames: number[] } {
  if (h.frames.length > 0 && h.unsyncedCount > h.frames.length) {
    throw new Error("rehydratePlan: unsyncedCount exceeds stored frames");
  }
  // EXP1C W4: real stored seqIds when the hydration carries them
  // (hydrate() entries); index fallback only for pre-entries callers.
  // WSKEP-R1 (BK-WSKEP F2): an entries-present-but-short shape used to fall
  // back to index-derived seqIds SILENTLY — make the drift loud (no current
  // caller can produce it; a future one must not hide behind the fallback).
  if (h.entries && h.entries.length !== h.frames.length) {
    console.warn(
      `rehydratePlan: entries.length (${h.entries.length}) !== frames.length (${h.frames.length}) — index fallback in use; stored seqIds untrusted for this hydration`,
    );
  }
  const seqs =
    h.entries && h.entries.length === h.frames.length
      ? h.entries.map((e) => e.seqId)
      : h.frames.map((_, i) => i + 1);
  return {
    currentSeq: h.currentSeq,
    unsyncedCount: h.unsyncedCount,
    ackedTo: ackCursor,
    frames: seqs,
  };
}

// --- host-side helpers (type surface for the page + courts) -----------------

export type { Frame, CodecError };
