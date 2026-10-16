// isr-counter.ts — N-6 ISR stampede lane instrumentation.
//
// Module-level state is NOT reliably shared between Next.js route bundles in a
// production server, so the regeneration witness is an append-only JSONL event
// file (also serves as the disk-behavior evidence for the lane). Both the ISR
// page and the /api/bench/isr-stats route import this module; every event is a
// fsync-free appendFileSync line — crash-safe, race-tolerant (append is atomic
// enough for single-process writers), and replayable.
//
// Event path overridable via ISR_BENCH_EVENTS (driver and server must agree).

import fs from "node:fs";
import path from "node:path";

export const EVENTS_PATH =
  process.env.ISR_BENCH_EVENTS ||
  path.join(process.cwd(), ".bench", "n6-isr-events.jsonl");

// Revalidate window used by app/bench/news/[slug]/page.tsx (seconds).
export const REVALIDATE_SECONDS = 10;

// 1 primary stampede slug + 50 dependent slugs for the on-demand phase.
export const PRIMARY_SLUG = "isr-stampede-primary";
export const DEPENDENT_SLUGS = Array.from(
  { length: 50 },
  (_, i) => `isr-dependent-${String(i).padStart(2, "0")}`,
);
export const ALL_SLUGS = [PRIMARY_SLUG, ...DEPENDENT_SLUGS];

export function appendEvent(ev: Record<string, unknown>): void {
  fs.mkdirSync(path.dirname(EVENTS_PATH), { recursive: true });
  fs.appendFileSync(EVENTS_PATH, JSON.stringify({ t: Date.now(), ...ev }) + "\n");
}

// Called inside the page render: fires on build-time prerender AND on every
// real runtime regeneration past the revalidate window (ISR never re-renders
// a fresh entry just to serve a hit, so this IS the rebuild witness).
export function recordRegeneration(slug: string): void {
  appendEvent({
    type: "regeneration",
    slug,
    phase: process.env.NEXT_PHASE || "runtime",
  });
}

// Driver-reported: number of responses served from a stale entry
// (x-nextjs-cache: STALE) observed on the wire during the burst.
export function recordStaleServed(n: number): void {
  appendEvent({ type: "stale-served", count: n });
}

export function resetEvents(): void {
  fs.mkdirSync(path.dirname(EVENTS_PATH), { recursive: true });
  fs.writeFileSync(EVENTS_PATH, "");
}

export type IsrStats = {
  regenerations: number;
  staleServed: number;
  regenerationsRuntime: number;
  perSlug: Record<string, number>;
  lastRegenerationAt: Record<string, number>;
};

export function readStats(): IsrStats {
  const stats: IsrStats = {
    regenerations: 0,
    staleServed: 0,
    regenerationsRuntime: 0,
    perSlug: {},
    lastRegenerationAt: {},
  };
  let raw = "";
  try {
    raw = fs.readFileSync(/* turbopackIgnore: true */ EVENTS_PATH, "utf8");
  } catch {
    return stats;
  }
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      const ev = JSON.parse(line);
      if (ev.type === "regeneration") {
        stats.regenerations += 1;
        if ((ev.phase || "runtime") === "runtime") stats.regenerationsRuntime += 1;
        stats.perSlug[ev.slug] = (stats.perSlug[ev.slug] || 0) + 1;
        stats.lastRegenerationAt[ev.slug] = ev.t;
      } else if (ev.type === "stale-served") {
        stats.staleServed += Number(ev.count) || 0;
      }
    } catch {
      // torn final line on a crash — tolerated by append-only design
    }
  }
  return stats;
}

// Deterministic fetch-free fixture content, generated server-side per slug.
export function articleFor(slug: string) {
  if (!/^[a-z0-9-]{1,64}$/.test(slug)) return null;
  let h = 0;
  for (let i = 0; i < slug.length; i++) h = (h * 31 + slug.charCodeAt(i)) >>> 0;
  const generatedAt = new Date().toISOString();
  return {
    slug,
    title: `Bench article ${slug}`,
    body: `Deterministic fixture body for ${slug} (hash ${h.toString(16)}).`,
    generatedAt,
  };
}
