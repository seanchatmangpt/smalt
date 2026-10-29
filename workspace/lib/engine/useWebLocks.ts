"use client";

/**
 * W3C-E row 8 — reactive face of the Web Locks master lease.
 *
 * tab-lease.ts owns the cross-tab mechanics (`withWalLease` over
 * `navigator.locks.request("lawinput_wal_lock")`, peer guard, typed
 * fallback). This module is the React face per Pattern-16 conventions:
 * a module-scoped singleton core (one lease world per page) surfaced
 * through `useSyncExternalStore`, with a `getServerSnapshot` so SSR
 * renders the INITIALIZING default without touching `navigator.locks`
 * (pattern 13 client boundary). Composes tab-lease — it does not
 * re-implement the mutex.
 *
 * Standing is disclosed, never dropped: the snapshot carries whether
 * the runtime actually has `navigator.locks`, which mode last executed
 * a leased body ("web-locks" | "fallback" | "never-held"), and how
 * many bodies currently hold/wait — a fallback tab shows the degraded
 * posture loudly.
 *
 * Row-8 secondary-observer law: a tab that is not the master does not
 * append. The core exposes `isMaster` so replica observers can gate
 * writes; append+drain bodies themselves still ride `withWalLease`.
 */

import { useSyncExternalStore } from "react";
import {
  WAL_LOCK_NAME,
  withWalLease,
  type LeaseMode,
  type WalLeaseOptions,
} from "./tab-lease";

/** Reactive standing of the master WAL lease (row 8). */
export interface WebLocksSnapshot {
  /** True iff `navigator.locks` exists in this runtime. */
  supported: boolean;
  /** Mode of the last executed leased body; "never-held" before the first. */
  lastMode: LeaseMode | "never-held";
  /** True iff the runtime has Web Locks AND the last body ran under the real lease. */
  isMaster: boolean;
  /** Bodies currently in flight under the lease (held + waiting). */
  inFlight: number;
  /** The master lease literal pinned by tranche row 8. */
  lockName: string;
}

export function initialWebLocksSnapshot(): WebLocksSnapshot {
  return {
    supported: false,
    lastMode: "never-held",
    isMaster: false,
    inFlight: 0,
    lockName: WAL_LOCK_NAME,
  };
}

type Listener = () => void;

/** Framework-free core so node courts can exercise the real logic. */
export class WebLocksCore {
  private snapshot: WebLocksSnapshot = initialWebLocksSnapshot();
  private listeners = new Set<Listener>();

  getSnapshot = (): WebLocksSnapshot => this.snapshot;

  subscribe = (fn: Listener): (() => void) => {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  };

  private patch(p: Partial<WebLocksSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...p };
    for (const fn of this.listeners) fn();
  }

  /** Re-derive support from the live runtime (SSR-safe, never throws). */
  probeSupport(): boolean {
    const nav = (globalThis as {
      navigator?: { locks?: { request?: unknown } };
    }).navigator;
    const supported = typeof nav?.locks?.request === "function";
    this.patch({ supported });
    return supported;
  }

  /**
   * Run `fn` under the master WAL lease (delegates to tab-lease
   * `withWalLease`); the snapshot's lease standing moves with the real
   * outcome — never ahead of it.
   */
  async runUnderLease<T>(
    fn: () => Promise<T>,
    opts: WalLeaseOptions = {},
  ): ReturnType<typeof withWalLease<T>> {
    this.probeSupport();
    this.patch({ inFlight: this.snapshot.inFlight + 1 });
    try {
      const r = await withWalLease(fn, opts);
      this.patch({
        lastMode: r.ok ? r.mode : this.snapshot.lastMode,
        isMaster: r.ok && r.mode === "web-locks",
      });
      return r;
   } finally {
      this.patch({ inFlight: this.snapshot.inFlight - 1 });
    }
  }
}

/** The module-scoped lease world (pattern 16). */
export const globalWebLocks = new WebLocksCore();

/** Reactive hook — server snapshot is the unsupported default (pattern 13). */
export function useWebLocks(): WebLocksSnapshot {
  return useSyncExternalStore(
    globalWebLocks.subscribe,
    globalWebLocks.getSnapshot,
    initialWebLocksSnapshot,
  );
}
