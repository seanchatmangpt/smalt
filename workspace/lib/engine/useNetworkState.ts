"use client";

/**
 * BK-130 / RU-3 adoption #2 — pattern-port of react-use's `useNetwork`
 * (streamich/react-use v17.6.1, Unlicense), per RU-4 Option C: no npm dep,
 * Unlicense prior-art disclosure in the header, law-compliant by
 * construction (no absolute paths, domain-blind).
 *
 * Online standing + connection-quality snapshot (downlink Mbps / RTT ms,
 * `navigator.connection` when present — disclosed as `unknown` elsewhere).
 *
 * Wiring (RU-3 item 2): flushSync gates on offline — an offline tab skips
 * the flush with a typed `OFFLINE` refusal (no burned 401/HTTP-error
 * cycle), and flushes on reconnect. The reconnect leg reuses the existing
 * snapback law (`snapbackStoreOps.listUnacked` / flushSync): whatever the
 * server never acked is still in the WAL and drains on `online`.
 *
 * The decision logic lives in the framework-free `gateFlushOnNetwork` /
 * `onlineClass` so the node court exercises them without React and without
 * a real network (fake events, deterministic).
 */

import { useEffect, useState } from "react";

/** Connection-quality snapshot (typed `unknown` where the API is absent). */
export interface NetworkQuality {
  /** Effective downlink estimate, Mbps. */
  downlink: number | "unknown";
  /** Round-trip-time estimate, ms. */
  rtt: number | "unknown";
  /** Effective connection class ("4g", "slow-2g", …). */
  effectiveType: string | "unknown";
}

export interface NetworkSnapshot extends NetworkQuality {
  online: boolean;
}

/** Framework-free online class: "online" | "offline" (typed, never implicit). */
export type OnlineClass = "online" | "offline";

/** Typed refusal shape for the gated flush (matches JournalError style). */
export interface OfflineRefusal {
  code: "OFFLINE";
  detail: string;
}

export type GatedFlushResult =
  | { skipped: true; refusal: OfflineRefusal }
  | { skipped: false };

/** Pure: classify a boolean online standing (the court's deterministic seam). */
export function onlineClass(online: boolean): OnlineClass {
  return online ? "online" : "offline";
}

/**
 * Pure decision: does a flush run now? Offline → typed `OFFLINE` skip, the
 * flush callable is never invoked (no network attempt is made). Online →
 * run. Framework-free so the court drives it with real calls.
 */
export function gateFlushOnNetwork(
  online: boolean,
  flush: () => Promise<unknown>,
): GatedFlushResult & { promise?: Promise<unknown> } {
  if (!online) {
    return {
      skipped: true,
      refusal: {
        code: "OFFLINE",
        detail: "flushSync skipped: navigator.onLine === false",
      },
    };
  }
  return { skipped: false, promise: flush() };
}

/**
 * Reconnect wiring (the snapback law's drain-on-online leg): on an
 * offline→online transition, whatever the server never acked is unacked
 * above the cursor — flush it. Returns the pure transition verdict the
 * hook applies; deterministic, court-drivable.
 */
export function isReconnect(prev: boolean, next: boolean): boolean {
  return !prev && next;
}

/** Read the current snapshot from real browser APIs (SSR-safe defaults). */
export function readNetworkSnapshot(): NetworkSnapshot {
  if (typeof navigator === "undefined") {
    return { online: true, downlink: "unknown", rtt: "unknown", effectiveType: "unknown" };
  }
  const conn = (navigator as unknown as {
    connection?: { downlink?: number; rtt?: number; effectiveType?: string };
  }).connection;
  return {
    online: navigator.onLine,
    downlink: typeof conn?.downlink === "number" ? conn.downlink : "unknown",
    rtt: typeof conn?.rtt === "number" ? conn.rtt : "unknown",
    effectiveType: typeof conn?.effectiveType === "string" ? conn.effectiveType : "unknown",
  };
}

/** React hook: reactive online + quality snapshot with listener teardown. */
export function useNetworkState(): NetworkSnapshot {
  const [snap, setSnap] = useState<NetworkSnapshot>(readNetworkSnapshot);

  useEffect(() => {
    // no synchronous setState here: the lazy useState initializer already
    // read the live snapshot at client mount; listeners carry updates.
    const update = () => setSnap(readNetworkSnapshot());
    window.addEventListener("online", update);
    window.addEventListener("offline", update);
    const conn = (navigator as unknown as { connection?: EventTarget }).connection;
    conn?.addEventListener?.("change", update);
    return () => {
      window.removeEventListener("online", update);
      window.removeEventListener("offline", update);
      conn?.removeEventListener?.("change", update);
    };
  }, []);

  return snap;
}
