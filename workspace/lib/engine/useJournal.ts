"use client";

/**
 * Pattern 16 — Reactive Hearth.
 *
 * A module-scoped singleton journal engine (one IndexedDB world per page)
 * surfaced to React through `useSyncExternalStore`, with a distinct
 * `getServerSnapshot` so the SSR shell renders INITIALIZING defaults without
 * ever touching IndexedDB (pattern 13 client boundary). Snapshot updates are
 * the only state mutation path — no per-component journal state.
 *
 * SPOF-4.1: the snapshot carries `leaseMode` ("locked" | "fallback" |
 * "unknown") — the master-lease standing is never dropped on the floor; a
 * degraded fallback tab is disclosed, and a fallback tab that detects a live
 * peer refuses appends typed (journal-sync `PEER_TAB_ACTIVE`).
 *
 * SPOF-4.2: every lease acquisition — the initial one included — re-checks
 * the store horizon (`needsRehydrate`) and, when a dead master left frames
 * the running snapshot never saw, rebuilds the accumulator and snapshot by
 * replay (`rehydratePlan`) BEFORE the leased body serves.
 */

import { useSyncExternalStore } from "react";
import { Accumulator, accumulatorKind } from "./merkle";
import {
  appendLocal,
  countUnsynced,
  flushSync,
  hydrate,
  needsRehydrate,
  nextSeqId,
  rehydratePlan,
  syncedCursor,
  unacked,
  type Hydrated,
  type JournalError,
} from "./journal-sync";
import { PeerGuard, toSnapshotLeaseMode, type SnapshotLeaseMode } from "./tab-lease";

export interface JournalSnapshot {
  /** True once Cold Ash Rehydration (pattern 5) has completed client-side. */
  ready: boolean;
  /** Derived terminal standing (pattern 19 refines it with andon standing). */
  phase:
    | "INITIALIZING"
    | "READY_STANDALONE"
    | "COMMITTED_LOCAL"
    | "SYNCED_AND_SEALED"
    | "SYNC_REFUSED_BY_SERVER";
  /** Highest journaled seqId (0 when fresh). */
  currentSeq: number;
  /** Segments above the ack cursor. */
  unsyncedCount: number;
  /** Ack floor from the server receipt. */
  ackedTo: number;
  /** Latest server receipt token ("" before the first sync). */
  receipt: string;
  /** P12: decoded receipt byte length (0 before first sync / on refusal). */
  receiptBytes: number;
  /** P12: receipt root matched the local leaf chain (false until verified). */
  receiptVerified: boolean;
  /** Journaled frame seqIds, ascending — the role="log" frame trail. */
  frames: number[];
  accumulatorKind: string;
  accumulatorRoot: string;
  /** SPOF-4.1: master-lease standing — never dropped, degraded is disclosed. */
  leaseMode: SnapshotLeaseMode;
}

export function initialJournalSnapshot(): JournalSnapshot {
  return {
    ready: false,
    phase: "INITIALIZING",
    currentSeq: 0,
    unsyncedCount: 0,
    ackedTo: 0,
    receipt: "",
    receiptBytes: 0,
    receiptVerified: false,
    frames: [],
    accumulatorKind: "sha256-chain",
    accumulatorRoot: "",
    leaseMode: "unknown",
  };
}

type Listener = () => void;

export interface JournalEngineOptions {
  /** Peer-guard override (multi-engine hosts / courts). */
  peerGuard?: PeerGuard;
}

/** One journal world per module (per page lifetime). */
export class JournalSyncEngine {
  private snapshot: JournalSnapshot = initialJournalSnapshot();
  private listeners = new Set<Listener>();
  private acc = new Accumulator();
  private initPromise: Promise<void> | null = null;
  private rehydrating: Promise<void> = Promise.resolve();
  private readonly peerGuard?: PeerGuard;
  /** BK-83 AUTH-SEAM: bearer threaded into every sync() flushSync call. */
  private authToken: string = "";

  constructor(opts: JournalEngineOptions = {}) {
    this.peerGuard = opts.peerGuard;
  }

  /**
   * BK-83 AUTH-SEAM (browser wiring): set the bearer token threaded into
   * sync()'s flushSync call. Empty (default) = tokenless — enforce mode
   * answers the typed 401 challenge and the flush refuses SYNC_HTTP/401.
   */
  setAuthToken(token: string): void {
    this.authToken = token;
  }

  getSnapshot = (): JournalSnapshot => this.snapshot;

  subscribe = (fn: Listener): (() => void) => {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  };

  private emit(): void {
    for (const fn of this.listeners) fn();
  }

  private patch(p: Partial<JournalSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...p };
    this.emit();
  }

  /**
   * SPOF-4.1: record the observed lease mode on the snapshot — the mode bit
   * is surfaced, never collapsed into a normal success.
   */
  private onLeaseAcquired = (mode: import("./tab-lease").LeaseMode): void => {
    this.patch({ leaseMode: toSnapshotLeaseMode(mode) });
  };

  /**
   * SPOF-4.2 — rehydrate on promotion: after ANY lease acquisition, if the
   * store holds seqIds the running snapshot never saw (a dead master
   * appended past this tab's init horizon), rebuild the accumulator and
   * snapshot from the stored frames before the leased body serves.
   */
  private maybeRehydrate = async (): Promise<void> => {
    const nxt = await nextSeqId();
    if (!nxt.ok) return;
    if (!needsRehydrate(this.snapshot.currentSeq, nxt.value - 1)) return;
    const h = await hydrate();
    if (!h.ok) {
      this.patch({ phase: "SYNC_REFUSED_BY_SERVER" });
      return;
    }
    const cur = await syncedCursor();
    await this.rebuildFrom(h.value, cur.ok ? cur.value : 0);
  };

  /** Serialized rehydrate — leased bodies in one tab never race the rebuild. */
  private rehydrate(): Promise<void> {
    this.rehydrating = this.rehydrating.then(this.maybeRehydrate, this.maybeRehydrate);
    return this.rehydrating;
  }

  /** Rebuild acc + snapshot by replaying the stored frames (idempotent). */
  private async rebuildFrom(h: Hydrated, ackCursor: number): Promise<void> {
    const acc = new Accumulator();
    for (const frame of h.frames) {
      await acc.append(frame);
    }
    this.acc = acc;
    this.patch({
      ready: true,
      ...rehydratePlan(h, ackCursor),
      accumulatorRoot: acc.rootHex(),
      accumulatorKind: accumulatorKind(),
    });
  }

  /**
   * Pattern 5 — Cold Ash Rehydration: restore seq/merkle horizon from
   * IndexedDB BEFORE the phase leaves INITIALIZING. The accumulator is
   * rebuilt by replaying stored frames (exact chain, O(n) once per page);
   * the choice is documented in journal-sync.hydrate().
   */
  init(): Promise<void> {
    if (!this.initPromise) {
      this.initPromise = (async () => {
        const h = await hydrate();
        if (!h.ok) {
          this.patch({ phase: "SYNC_REFUSED_BY_SERVER" });
          return;
        }
        const cur = await syncedCursor();
        await this.rebuildFrom(h.value, cur.ok ? cur.value : 0);
        this.patch({ phase: "READY_STANDALONE" });
      })();
    }
    return this.initPromise;
  }

  // --- journal-sync passthroughs (snapshot updated as the real state moves) --

  async append(clientId: bigint, op: number, payload: Uint8Array): Promise<void> {
    // W3C-E row 8 + SPOF-4.3: the append rides the lease-wrapped module
    // surface; the onAcquired hook rehydrates before the body mints a seq.
    const appended = await appendLocal(clientId, op, payload, {
      peerGuard: this.peerGuard,
      onAcquired: (mode) => {
        this.onLeaseAcquired(mode);
        return this.rehydrate();
      },
    });
    if (!appended.ok) {
      this.patch({ phase: "SYNC_REFUSED_BY_SERVER" });
      return;
    }
    await this.acc.append(new Uint8Array(appended.value.frame));
    const seq = appended.value.seqId;
    this.patch({
      phase: "COMMITTED_LOCAL",
      currentSeq: Math.max(this.snapshot.currentSeq, seq),
      frames: [...this.snapshot.frames, seq],
      unsyncedCount: this.snapshot.unsyncedCount + 1,
      accumulatorRoot: this.acc.rootHex(),
    });
  }

  async sync(): Promise<{ ok: boolean; error?: JournalError; lastSeq: number }> {
    // W3C-E row 8 + SPOF-4.3: the drain holds the master WAL lease on the
    // lease-wrapped module surface; rehydrate runs before the batch read.
    const res = await flushSync({
      peerGuard: this.peerGuard,
      authHeader: this.authToken,
      onAcquired: (mode) => {
        this.onLeaseAcquired(mode);
        return this.rehydrate();
      },
    });
    if (!res.ok) {
      // P12 honesty: a refused sync never claims a verified seal.
      this.patch({ phase: "SYNC_REFUSED_BY_SERVER", receiptVerified: false });
      return { ok: false, error: res.error, lastSeq: 0 };
    }
    const ua = await unacked();
    const cur = await syncedCursor();
    const unsynced = ua.ok ? countUnsynced(ua.ok ? ua.value : [], cur.ok ? cur.value : 0) : this.snapshot.unsyncedCount;
    this.patch({
      phase: "SYNCED_AND_SEALED",
      unsyncedCount: unsynced,
      ackedTo: cur.ok ? cur.value : this.snapshot.ackedTo,
      receipt: res.value.receiptToken || this.snapshot.receipt,
      receiptBytes: res.value.receiptBytes,
      receiptVerified: res.value.verified,
    });
    return { ok: true, lastSeq: res.value.lastSeq };
  }

  // --- public getters the reference wiring expects ---------------------------

  getUnsyncedFrames(): Promise<number> {
    return (async () => {
      const ua = await unacked();
      const cur = await syncedCursor();
      return ua.ok ? countUnsynced(ua.value, cur.ok ? cur.value : 0) : this.snapshot.unsyncedCount;
    })();
  }

  getCurrentSeq(): Promise<number> {
    return Promise.resolve(this.snapshot.currentSeq);
  }
}

/** The module-scoped hearth (pattern 16). */
export const globalJournalEngine = new JournalSyncEngine();

/** Reactive hook — server snapshot is the INITIALIZING default (pattern 13). */
export function useJournal(): JournalSnapshot {
  return useSyncExternalStore(
    globalJournalEngine.subscribe,
    globalJournalEngine.getSnapshot,
    initialJournalSnapshot,
  );
}
