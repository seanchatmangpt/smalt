"use client";

/**
 * BK-130 / RU-3 adoption #4 — pattern-port of react-use's document
 * `visibilitychange` sensor (streamich/react-use v17.6.1, Unlicense), per
 * RU-4 Option C: no npm dep, prior-art disclosure in header, domain-blind,
 * SSR-safe (server default "visible", no document access at render).
 *
 * Wiring (RU-3 item 4): flush-on-resume — on `visible` after a hidden
 * span, attempt `sync()` (catch-up after tab suspension, including Web
 * Locks handed off while hidden; pairs with rehydrate-on-promotion).
 *
 * The transition math lives in the framework-free `resumeAfterHidden` so
 * the node court drives it with fake events, deterministically.
 */

import { useEffect, useState } from "react";

export type VisibilityState = "visible" | "hidden" | "prerender";

/** Framework-free resume verdict: hidden → visible is a resume. */
export function resumeAfterHidden(prev: VisibilityState, next: VisibilityState): boolean {
  return prev !== "visible" && next === "visible";
}

/** SSR-safe read of the current visibility (no document access server-side). */
export function readVisibility(): VisibilityState {
  if (typeof document === "undefined") return "visible";
  return document.visibilityState === "hidden" ? "hidden" : "visible";
}

/** React hook: reactive document visibility with listener teardown. */
export function useVisibility(): VisibilityState {
  const [vis, setVis] = useState<VisibilityState>(readVisibility);

  useEffect(() => {
    // no synchronous setState: the lazy initializer already read live
    // visibility at client mount; the listener carries updates.
    const onVis = () => setVis(readVisibility());
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, []);

  return vis;
}

/**
 * Wiring helper the page applies on resume: `if (resumeAfterHidden(prev, next))
 * void flushSync()`. Exposed so the court exercises the exact predicate.
 */
export { resumeAfterHidden as flushOnResume };
