"use client";

/**
 * BK-130 / RU-3 adoption #3 — pattern-port of react-use's `useIdle`
 * (streamich/react-use v17.6.1, Unlicense), per RU-4 Option C: no npm dep,
 * prior-art disclosure in header, domain-blind, no absolute paths.
 *
 * Idle detection from real activity events (mouse/keys/pointer/scroll/
 * touch). Wiring (RU-3 item 3, the pharma/defense drain-before-walk-away
 * requirement): idle ≥ N ms with unsynced frames → attempt the flush
 * (`syncUpstream`), so the journal drains before the operator walks away.
 *
 * The timing math lives in the framework-free `IdleCore` so the node court
 * drives it with injected timestamps (deterministic, no clock guessing —
 * the court observes state, it does not sleep).
 */

import { useEffect, useState } from "react";

/** Default idle threshold for the auto-flush (30s, RU-3's range). */
export const DEFAULT_IDLE_FLUSH_MS = 30_000;

/** Activity events the hook listens to (vendor's set, trimmed). */
export const ACTIVITY_EVENTS = [
  "mousemove",
  "mousedown",
  "keydown",
  "touchstart",
  "scroll",
  "wheel",
] as const;

/** Framework-free idle math — one per page, driven by injected time. */
export interface IdleCore {
  /** Record an activity event at time `t` (ms epoch). */
  noteActivity: (t: number) => void;
  /** Is the session idle as of `now`? */
  isIdle: (now: number) => boolean;
  /** ms since the last activity as of `now`. */
  idleFor: (now: number) => number;
  /**
   * Wiring decision (RU-3 item 3): idle ≥ `timeoutMs` AND unsynced frames
   * exist → attempt the auto-flush. Deterministic in (t, now).
   */
  shouldAutoFlush: (now: number, unsyncedCount: number, timeoutMs?: number) => boolean;
}

/** Mint a fresh idle core with a start-of-time activity stamp. */
export function createIdleCore(timeoutMs: number = DEFAULT_IDLE_FLUSH_MS): IdleCore {
  let lastActivity = 0;
  const limit = timeoutMs;
  return {
    noteActivity(t: number) {
      lastActivity = Math.max(lastActivity, t);
    },
    isIdle(now: number) {
      return now - lastActivity >= timeoutMs;
    },
    idleFor(now: number) {
      return Math.max(0, now - lastActivity);
    },
    shouldAutoFlush(now: number, unsyncedCount: number, overrideMs?: number) {
      const ms = overrideMs ?? limit;
      return now - lastActivity >= ms && unsyncedCount > 0;
    },
  };
}

export interface IdleSnapshot {
  isIdle: boolean;
  lastActivity: number;
}

/** React hook: idle standing from real activity events, torn down on unmount. */
export function useIdle(timeoutMs: number = DEFAULT_IDLE_FLUSH_MS): IdleSnapshot {
  const [core] = useState(createIdleCore);
  const [snap, setSnap] = useState<IdleSnapshot>({ isIdle: false, lastActivity: 0 });

  useEffect(() => {
    const note = () => {
      core.noteActivity(Date.now());
      setSnap({ isIdle: core.isIdle(Date.now()), lastActivity: Date.now() });
    };
    for (const ev of ACTIVITY_EVENTS) window.addEventListener(ev, note, { passive: true });
    // initial stamp: the mount itself is activity
    note();
    return () => {
      for (const ev of ACTIVITY_EVENTS) window.removeEventListener(ev, note);
    };
  }, [core, timeoutMs]);

  return snap;
}
