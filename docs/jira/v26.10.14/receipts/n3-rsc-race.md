# N-3 RSC Streaming Race Bench — Receipt

- **Lane**: N-3 (workspace/app/bench/audit)
- **Date**: 2026-10-16
- **Subject**: `/bench/audit/[id]` streaming RSC route (3 Suspense chunks, 100/300/600 ms) + index; 50-round rapid sibling navigation DURING streaming under CDP network emulation (50 ms latency + 0–100 ms per-request jitter / chunk-reorder pressure via route-level randomized delay).
- **Runner**: `scripts/bench/n3_rsc_race.spec.mjs` (Playwright chromium + CDP `Network.emulateNetworkConditions`, `Performance.getMetrics`), against `next start` (:3100), Next.js 16.4.2, Turbopack production build.
- **Data**: `docs/jira/v26.10.14/bench/n3-rsc-race.jsonl` (50 per-round rows + summary per run; last run's rows are current).

## Falsifier verdicts (final run, 2026-10-16T04:18:00Z)

| Falsifier | Threshold | Measured | Verdict |
|---|---|---|---|
| Unhandled rejections (`pageerror`) | 0 | **1** — Minified React error #412 (hydration interrupted by mid-stream navigation) | **FAIL (flaky)** |
| Heap growth over 50 navigations (`JSHeapUsedSize`) | < 150 MB | **53.33 MB** (3.6 MB → 59.6 MB) | **PASS** |
| Lingering pending `/bench/audit/*` fetches at end | 0 | **0** (aborted-by-nav total 0; `Network.getResponseBody` failures 0) | **PASS** |

Hydration flash count (fallback nodes appearing post-hydration): **0** (informational).

## Run history (same spec, 50 rounds each)

| Run | pageErrors | Heap growth | Notes |
|---|---|---|---|
| 1 | 51 | 72.96 MB | 1× spec-bug error + React #412 per round — pre-probe-fix |
| 2 | 52 | 78.82 MB | MutationObserver probe bug (`documentElement` not a Node at init) + React #412 storm |
| 3 | 0 | 54.85 MB | probe fixed; clean PASS |
| 4 (final) | 1 | 53.33 MB | React #412 resurfaced once — race is intermittent |

## Finding: React #412 hydration-interrupt race (FLAKY, race-dependent)

Clicking a sibling route before the prior RSC stream completes can surface
**Minified React error #412** as an uncaught page error. Intermittent: 0 in two
runs, 1 in another, ~1/round in runs where the probe bug perturbed timing.
The root does NOT crash — the app continues rendering and completing
navigations after the error (all 50 rounds complete; final `[data-page]`
present). Classification: recovered hydration interruption surfacing through
the error channel rather than a root kill — but it violates a strict
zero-`pageerror` gate and should be tracked upstream (React 19 / Next 16
router abort path).

## Cross-lane unblock fixes (disclosed, minimal, per compile-freeze SLA)

The shared workspace build was broken by other lanes' files; minimal fixes
applied to unblock `next build` (no `lib/` semantic edits; each is behavior-
preserving):

1. `workspace/app/bench/grid/page.tsx:234` — `</fullwidget>` closing tag with
   no opener → `</div>` (balanced the row-list container div).
2. `workspace/lib/bench/topo-worker.ts:15` — `declare const self: DedicatedWorkerGlobalScope`
   (redeclare of global `self`; `DedicatedWorkerGlobalScope` unresolved) →
   `const self = globalThis as unknown as {postMessage; onmessage}` + `export {}`
   (file had no imports/exports, so top-level `const self` collided with the
   DOM global).
3. `workspace/app/bench/metrics/route.ts:3` — `IntervalHistogram` is not an
   exported member of `node:perf_hooks` under installed `@types/node` →
   `type IntervalHistogram = ReturnType<typeof monitorEventLoopDelay>`.
4. `workspace/app/bench/action/page.tsx:111` — `revalidateTag(tag)` requires a
   second argument in Next 16 → `revalidateTag("bench-n2-action", "max")`.
5. `workspace/app/bench/news/[slug]/page.tsx:18` — non-literal segment config
   `export const revalidate = REVALIDATE_SECONDS` is rejected by Next 16 →
   literal `10` (kept in lockstep with `REVALIDATE_SECONDS = 10` in
   `lib/bench/isr-counter.ts`).

## Environment notes

- Shared checkout under concurrent lane load: route latency observed up to
  ~2.4 s (vs. the 100/300/600 ms staged delays), which thickens the
  during-stream race window; spec tolerates this (`navMissing` fallback with
  goto; recorded per round, 0 occurrences in final runs).
- Server: `next start -p 3100` on BUILD_ID `tRfKtZtHkeEltUibHtWVG`.
- No commits made; no `lib/` business-logic edits (topo-worker typing fix is a
  disclosed exception per SLA, behavior-preserving).
