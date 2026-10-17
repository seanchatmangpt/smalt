# N-2 Action Storm Receipt

Lane: N-2 lifecycle stress · subject: `workspace` (Next.js 16.4.2 / React 19)
production server (`next start`, port 4620, single node process, node v26.10.0).

## Subject

- `workspace/app/bench/action/page.tsx` — page + inline `"use server"` action
  (plain shape validation, `revalidateTag("bench-n2-action", "max")`,
  AsyncLocalStorage request-id context, cookie-echoed request id).
- `workspace/app/bench/action/store.ts` — `AsyncLocalStorage` instance +
  request-id minting.
- `workspace/app/bench/metrics/route.ts` — `/bench/metrics` sidecar
  (`perf_hooks.monitorEventLoopDelay`, 10 ms resolution, `?reset=1`
  per-interval windows), same server process as the actions.
- `scripts/bench/n2_action_storm.mjs` — hand-rolled keep-alive fetch pool
  (2,000 VUs, 1 socket per VU), multipart form-encoded action POSTs on the
  progressive-enhancement path (`$ACTION_ID_<id>` hidden field; Next 16 does
  not support urlencoded action bodies — the action handler bails on
  `application/x-www-form-urlencoded`).

## Method

- Build: `next build` (Turbopack, 58 routes, TypeScript pass after fixing a
  pre-existing `const self` DOM-global redeclare in another lane's
  `workspace/lib/bench/topo-worker.ts` — compile-freeze SLA unblock fix,
  disclosed).
- Action ID pinned from `.next/server/server-reference-manifest.json`
  (`40f64d86a82b62e120c688dcd9c4d2dc11469c74b4`), injected via `N2_ACTION_ID`.
- Workload per global counter: every 20th POST invalid (bad sku), every 50th
  iteration a raced double submission (2 identical POSTs), rest valid unique.
  2,000 VUs x 25 iterations = 50,000 planned requests per storm run.
- Metrics: client-side latency percentiles; event-loop delay polled at 1 Hz
  from `/bench/metrics?reset=1` (same process); invalid-payload rejection via
  `n2_verdict=rejected` cookie; session-leak falsifier via unique
  `n2_rid` set-cookie echo (duplicate rid under concurrent load = ALS
  cross-request pollution).

## Results

| run | vus | accepted | rejected/invalid | leaks | unique rids | transport err | p50 | p95 | p99 | max | ops/s | eld max |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| storm 1 | 2000 | 45067 | 2322/2322 (100%) | 0 | 45067 | 3611 | 196 | 369 | 8177 | 17331 | 1016 | 346 |
| storm 2 | 2000 | 46118 | 2374/2374 (100%) | 0 | 46118 | 2508 | 176 | 430 | 10382 | 18526 | 1045 | 346 |
| probe (100 vus) | 100 | 4750 | 250/250 (100%) | 0 | 4750 | 0 | 88 | 130 | 142 | - | 1129 | - |

Rows: `docs/jira/v26.10.14/bench/n2-action-storm.jsonl` (3 rows).

## Falsifier verdicts

| falsifier | verdict | evidence |
|---|---|---|
| F1 session leak (ALS cross-request pollution) | PASS | 0 duplicate/foreign `n2_rid` echoes across 95,935 accepted actions (incl. 1,000 raced double-submission pairs per storm run); every accepted response echoed a unique rid (unique_rids == accepted) |
| F2 invalid rejection 100% | PASS | 2322/2322 and 2374/2374 and 250/250; `valid_bounced=0` |
| F3 action p99 <= 350 ms at 2,000 VUs | FAIL | p99 = 8.2 s / 10.4 s across two runs; max 17.3 s / 18.5 s |

F3 diagnosis (mechanical evidence, not apology):

- Server throughput plateaus at ~1,050-1,130 actions/s regardless of offered
  concurrency (1016/s at 2000 VU vs 1129/s at 100 VU). Above that, latency is
  queueing, not execution: event-loop delay stays low (mean 11-12 ms,
  per-interval p99 max 71 ms) while request latency explodes — the server is
  accept-queue/concurrency-bound, not event-loop-bound.
- 2,506/2,508 transport errors are client `ETIMEDOUT` (+2 `ECONNRESET`):
  `kern.ipc.somaxconn=128` on this host caps the listen backlog, so a 2,000
  concurrent burst overflows the accept queue and sockets time out before
  accept. This is a host/kernel config finding, not an action regression.
- Capacity point: at 100 VUs the same action path holds p99 = 142 ms with zero
  transport errors — F3 passes at the server's saturation capacity and fails
  only above it.

## Standing

PARTIAL_ALIVE — F1/F2 unfalsified (ALS isolation and validation rejection hold
under storm); F3 falsified at the mandated 2,000 VU concurrency, bounded by a
100 VU capacity probe (p99 142 ms, 0 transport errors). Teardown clean: server
stopped, port 4620 free, no stray processes.

## See Also

- `docs/jira/v26.10.14/bench/n2-action-storm.jsonl`
- `scripts/bench/flood_autocannon.mjs` (pattern source)
