"use client";

/**
 * W3C-E row 9 — service worker registration client component.
 *
 * Rendered once from the root layout; registers /sw.js on load. Registration
 * is best-effort: a refusal (insecure context, browser without SW) is
 * logged to the console and swallowed — the shell keeps working, the offline
 * capability simply is not armed.
 */

import { useEffect } from "react";

export default function SwRegister() {
  useEffect(() => {
    if (typeof navigator === "undefined" || !("serviceWorker" in navigator)) {
      return;
    }
    const on_load = () => {
      navigator.serviceWorker
        .register("/sw.js")
        .then((reg) => {
          console.info("[sw] registered, scope:", reg.scope);
        })
        .catch((e) => {
          console.warn("[sw] registration refused:", String(e));
        });
    };
    if (document.readyState === "complete") on_load();
    else window.addEventListener("load", on_load, { once: true });
    return () => window.removeEventListener("load", on_load);
  }, []);

  return null;
}
