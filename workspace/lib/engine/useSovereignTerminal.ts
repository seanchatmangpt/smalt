"use client";

/**
 * Pattern 19 — derived terminal state machine.
 *
 * Status is DERIVED, never stored twice: journal phase (Reactive Hearth) is
 * overridden by andon standing (Ambient Cord) and by the last admitted
 * payload refusals. The admit/sync actions are the only writers.
 */

import { useCallback, useState } from "react";
import { lawWorkerBridge, type AdmitOutcome } from "./law-worker-bridge";
import { ensureClientId } from "./journal-sync";
import { globalJournalEngine, useJournal } from "./useJournal";
import { useAndon } from "./useAndon";
import { useAsyncFn } from "./useAsyncFn";

export type TerminalStatus =
  | "INITIALIZING"
  | "READY_STANDALONE"
  | "COMMITTED_LOCAL"
  | "SYNCED_AND_SEALED"
  | "HALTED_BY_SIEVE"
  | "SYNC_REFUSED_BY_SERVER";

export interface SovereignTerminal {
  status: TerminalStatus;
  currentSeq: number;
  unsyncedCount: number;
  receipt: string;
  /** P12: decoded receipt byte length (0 before first sync / on refusal). */
  receiptBytes: number;
  /** P12: receipt verified against the local leaf chain. */
  receiptVerified: boolean;
  frames: number[];
  /** Admit one payload through the pinned worker + journal hearth. */
  admitAndCommit: (payload: string) => Promise<void>;
  /** Flush un-acked frames upstream over smaltFetch. */
  syncUpstream: () => Promise<void>;
  /** BK-118: fresh-read in-flight standing (ref core, never stale). */
  busy: boolean;
  /** BK-118: captured error from the last rejected admit/sync. */
  error: unknown;
  /** BK-83 AUTH-SEAM: thread the sync bearer token (empty = tokenless). */
  setToken: (token: string) => void;
}

export function useSovereignTerminal(): SovereignTerminal {
  const snap = useJournal();
  const andon = useAndon();
  const [, setTick] = useState(0);

  // BK-118: one ported useAsyncFn per logical action. In-flight standing is
  // tracked in a ref core (fresh synchronous read inside callbacks, never a
  // closure-captured boolean); render reads use the state snapshot.
  const [admitState, admitRun, admitCore] = useAsyncFn();
  const [syncState, syncRun, syncCore] = useAsyncFn();

  const admitAndCommit = useCallback(
    async (payload: string) => {
      await admitRun(async () => {
        await globalJournalEngine.init();
        const bytes = new TextEncoder().encode(payload);
        const verdict: AdmitOutcome = await lawWorkerBridge.admit(bytes);
        if (verdict.status === "ANDON_REFUSAL") {
          andon.raise(verdict.rule);
          return;
        }
        // EXP1C W3: no hardcoded clientId 0n — the persisted per-origin
        // identity (random u64, sync_cursor store) rides every append, so
        // two consoles never collide on (0, seq) and the server's
        // per-client head tracking stays sound.
        const cid = await ensureClientId();
        if (!cid.ok) {
          throw new Error(`clientId unavailable: ${cid.error.code}`);
        }
        await globalJournalEngine.append(cid.value, 1, bytes);
      });
      // BK-118: a captured error surfaces to the ANDON cord (state, not throw).
      const err = admitCore.error; // fresh ref read inside a callback
      if (err !== undefined) {
        andon.raise(`BK118_ASYNC_ERROR: ${err instanceof Error ? err.message : String(err)}`);
      }
      setTick((n) => n + 1); // re-render so `busy`/`error` read fresh
    },
    [admitRun, admitCore, andon],
  );

  const syncUpstream = useCallback(async () => {
    await syncRun(async () => {
      await globalJournalEngine.init();
      await globalJournalEngine.sync();
    });
    const err = syncCore.error;
    if (err !== undefined) {
      andon.raise(`BK118_ASYNC_ERROR: ${err instanceof Error ? err.message : String(err)}`);
    }
    setTick((n) => n + 1);
  }, [syncRun, syncCore, andon]);

  // Derived status: the cord outranks the journal; sync refusal outranks the
  // last local commit; INITIALIZING until rehydration finishes (pattern 5).
  let status: TerminalStatus = snap.phase;
  if (snap.phase !== "INITIALIZING") {
    if (andon.raised) status = "HALTED_BY_SIEVE";
  }

  return {
    status,
    currentSeq: snap.currentSeq,
    unsyncedCount: snap.unsyncedCount,
    receipt: snap.receipt,
    receiptBytes: snap.receiptBytes,
    receiptVerified: snap.receiptVerified,
    frames: snap.frames,
    admitAndCommit,
    syncUpstream,
    busy: admitState.loading || syncState.loading,
    error: admitState.error ?? syncState.error,
    setToken: (token: string) => globalJournalEngine.setAuthToken(token),
  };
}
