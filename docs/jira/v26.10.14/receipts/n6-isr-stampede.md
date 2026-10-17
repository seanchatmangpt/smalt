# Receipt: N-6 ISR Stampede (lifecycle stress lane)

- **Date**: 2026-10-16
- **Lane**: N-6
- **Repo**: /Users/sac/smalt (one canonical checkout, no worktrees)
- **Subject**: production Next.js server (`next start`, Next 16.4.2, React 19.3.1, port 3116), ISR page `workspace/app/bench/news/[slug]/page.tsx` (`revalidate = 10`, fetch-free deterministic fixture content)
- **Driver**: `scripts/bench/n6_isr_stampede.mjs` (node 26.10.0, autocannon for cached-TTFB; node:http keep-alive herd for the stampede because per-response `x-nextjs-cache` headers are required)
- **JSONL**: `docs/jira/v26.10.14/bench/n6-isr.jsonl` (5 rows, verified on disk: P0/P1/P2/P3 + FINAL)
- **Witness**: append-only event log `workspace/.bench/n6-isr-events.jsonl` (53 lines), exposed via `/api/bench/isr-stats` (GET/POST)

## Files landed (lane-owned)

| file | role |
|---|---|
| `workspace/app/bench/news/[slug]/page.tsx` | ISR subject page (`revalidate = 10`, `generateStaticParams` over 51 fixture slugs, `recordRegeneration` in render = rebuild witness) |
| `workspace/lib/bench/isr-counter.ts` | append-only regeneration witness + fixture map + `/api/bench/isr-stats` + `/api/bench/isr-revalidate` backing module |
| `workspace/app/api/bench/isr-stats/route.ts` | GET `{regenerations, staleServed, perSlug, ...}`; POST driver-reported stale count / reset |
| `workspace/app/api/bench/isr-revalidate/route.ts` | POST `revalidatePath` trigger, one slug per call |
| `scripts/bench/n6_isr_stampede.mjs` | driver: cached TTFB -> expired-slug herd -> 50 parallel revalidatePath under continuous reads -> disk witness |
| `docs/jira/v26.10.14/bench/n6-isr.jsonl` | bench artifact (5 rows) |
| `docs/jira/v26.10.14/receipts/n6-isr-stampede.md` | this receipt |

## Commands / exits

| step | command | exit |
|---|---|---|
| build | `cd workspace && npx next build` | 0 (after N-2 lane type errors cleared from tree; N-3 applied a literal-`revalidate` unblock fix to this lane's page — kept) |
| serve | `PORT=3116 npx next start` | server up, smoke GET 200 |
| bench | `node scripts/bench/n6_isr_stampede.mjs` | 0 |

## Falsifier verdicts (final run 2026-10-16T04:14Z)

| falsifier | threshold | observed | verdict |
|---|---|---|---|
| F1 cached TTFB | p99 ≤ 45 ms | p50 14 ms / p99 27 ms (34,363 req, 100 conns, 0 errors) | **PASS** |
| F2 stampede dedup | ≤1 background rebuild per expired interval per slug | 10,000/10,000 x2xx, 0 transport errors; peak in-flight 1,000 (lsof peak 2,002 established incl. server side), STALE 6,139 / HIT 3,861, herd p50 136.6 ms / p99 306.9 ms; regenerations delta = **1** (baseline captured immediately pre-herd) | **PASS** |
| F3 on-demand correctness | 0 5xx, 0 stale-beyond-one-window, all 50 refreshed | 3,538 background reads, 50/50 revalidatePath in 28 ms, 0 read 5xx, 0 revalidate 5xx, stale-beyond-one-window **0**, 50/50 slugs serving post-revalidate content | **PASS** |

**All falsifiers PASS.** `FINAL allPass=true` recorded in the JSONL.

## Instrumentation notes (honesty ledger)

- Achieved concurrency recorded, not assumed: peak in-flight = socket cap 1,000;
  lsof sampled 2,002 established sockets on port 3116 (client+server sides of the
  same connections). The full 10,000-request herd ran concurrently at the socket
  cap; pipelining not needed. Autocannon cannot
  expose per-response `x-nextjs-cache` headers, so the stampede herd is a node:http keep-alive
  agent with `maxSockets=1000`; autocannon retained for the cached-TTFB phase.
- Regeneration witness = render-time `recordRegeneration()`; build-time
  prerenders are tagged `phase=phase-production-build` and excluded from the
  runtime count (`regenerationsRuntime`).
- F2 baseline is captured immediately before the herd so the delta counts only
  regenerations inside the single expired interval (an earlier warm rebuild is
  excluded by construction). First run measured 2 — diagnosed as the warm-phase
  rebuild being counted; driver corrected, not the threshold.
- P2 pre-warm loops each slug until it serves post-warm content; otherwise
  reads racing the warm rebuild serve build-era bodies and the staleness
  counter counts ISR-by-design stale-while-revalidate as violations (run 2
  showed 15 such reads; driver measurement corrected, threshold unchanged).
- Disk witness: `workspace/.next/cache` 50,692 KB; event log 53 lines / 4,536 B
  for the full run (append-only, crash-safe; torn final line tolerated on read).

## Cross-lane disclosures (compile-freeze SLA)

- `workspace/app/bench/compute/page.tsx` (untracked, another lane): minimal
  unblock fix — missing `}` (`);` -> `});`) that froze the build. Disclosed.
- N-3 lane applied a literal-`revalidate` unblock fix to this lane's
  `workspace/app/bench/news/[slug]/page.tsx` (segment config must be literals);
  kept, value still 10 and in lockstep with `REVALIDATE_SECONDS`.
- N-2 lane's type errors (action/page.tsx, metrics/route.ts, lib/bench/topo-worker.ts) cleared
  by that lane before my final build; not edited by this lane.

## Standing

ALIVE — all three falsifiers passed on the exact subject (production `next start`,
Next 16.4.2) with the run artifact on disk. No commits made (per lane contract);
`pkill next start` after the run; build-phase events excluded via phase tag.
