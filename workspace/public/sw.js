/**
 * W3C-E row 9 — console service worker.
 *
 * Precaches the app shell and the graphlaw WASM artifact so the console
 * cold-boots offline (aircraft/Faraday-class P4). Cache name is
 * build-pinned: a new deployment bumps CACHE and the activate phase purges
 * every stale cache, so no mixed-version shell ever serves.
 *
 * Air-gap law: same-origin GET only. Cross-origin requests and non-GET
 * requests pass through untouched. Navigations are network-first with cache
 * fallback for offline cold boot. Immutable hashed static assets and the
 * WASM artifact are cache-first.
 */

const CACHE = "console-shell-v1";
const PRECACHE = ["/", "/console", "/wasm/graphlaw.wasm"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE);
      await Promise.allSettled(
        PRECACHE.map((url) => cache.add(new Request(url, { cache: "reload" }))),
      );
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      for (const key of keys) {
        if (key !== CACHE) await caches.delete(key);
      }
      await self.clients.claim();
    })(),
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  if (req.mode === "navigate") {
    event.respondWith(
      (async () => {
        try {
          return await fetch(req);
        } catch {
          const cache = await caches.open(CACHE);
          const hit = await cache.match(req, { ignoreSearch: true });
          return (
            hit ||
            (await cache.match("/console")) ||
            (await cache.match("/")) ||
            Response.error()
          );
        }
      })(),
    );
    return;
  }

  if (url.pathname.startsWith("/_next/static/") || url.pathname === "/wasm/graphlaw.wasm") {
    event.respondWith(
      (async () => {
        const cache = await caches.open(CACHE);
        const hit = await cache.match(req);
        if (hit) return hit;
        const res = await fetch(req);
        if (res.ok) await cache.put(req, res.clone());
        return res;
      })(),
    );
  }
});
