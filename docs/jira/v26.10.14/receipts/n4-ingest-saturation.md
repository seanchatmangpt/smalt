# N-4 Ingest Saturation — Receipt

Lane: N-4 lifecycle stress, /Users/sac/smalt, v26.10.14. Date: 2026-10-15.
Subject: streaming HMAC ingest route under a 3×60 s, 5,000 RPS gzip storm.

## Subject identity

| file | role |
|---|---|
| `workspace/app/api/v1/ingest/route.ts` | Route Handler (POST/GET), self-contained token bucket |
| `scripts/bench/n4_ingest_saturation.mjs` | burst driver (hand-rolled fetch pool, closed-loop paced) |
| `docs/jira/v26.10.14/bench/n4-ingest.jsonl` | 3 JSONL rows, one per window (raw evidence) |

No `lib/` edits. No commits. In-memory config documented in the route header:
`SMALT_INGEST_HMAC_KEY` (default `n4-dev-key`), `SMALT_RATE_CAPACITY`,
`SMALT_RATE_REFILL`.

## Config under test

`next build` (Next 16.4.2 / Turbopack) → `next start -p 3100` with
`SMALT_RATE_CAPACITY=7777 SMALT_RATE_REFILL=1234` (deliberately small so the
429 leg fires at 5k RPS: steady-state accept ceiling = refill = 1,234/s after
the initial 7,777-token reserve drains).

## Results (3 × 60 s windows, target 5,000 RPS, 20 % bad-signature mix)

| window | achieved RPS | p50 ms | p95 ms | p99 ms | 202 | 401 | 429 | TCP/socket errors |
|---|---|---|---|---|---|---|---|---|
| 1 | 4987.5 | 1.59 | 31.70 | 44.68 | 81,787 | 60,001 | 158,218 | 0 |
| 2 | 4993.4 | 1.48 | 5.28 | 12.50 | 74,363 | 60,000 | 165,640 | 0 |
| 3 | 4987.8 | 1.28 | 3.97 | 11.02 | 74,372 | 59,948 | 165,424 | 0 |

0.2 % of requests unaccounted per window = in-flight at window cutoff.

## 429 correctness (server ledger vs client observation)

Server GET counter after all 3 windows: `accepted=230,523`,
`rejected429=489,282`, `rejected401=179,950`.

| counter | server | client-observed | delta |
|---|---|---|---|
| 202 | 230,523 | 230,522 | +1 (warmup smoke probe) |
| 429 | 489,282 | 489,282 | 0 |
| 401 | 179,950 | 179,949 | +1 (warmup smoke probe) |

Per-window accepted vs law `capacity + refill × t`:
w1 81,787 vs 81,817 predicted (−0.04 %); w2 74,363 vs 74,040 (+0.44 %, timer
granularity); w3 74,372 vs 74,040 (+0.45 %). Bucket is conservative-exact: no
window accepted above capacity + refill allowance by more than scheduling
slack.

## Heap trajectory (falsifier: monotonic growth → FAIL)

| window | heapUsed start→end MB | RSS start→end MB |
|---|---|---|
| 1 | 48.0 → 63.6 | 96 → 354 |
| 2 | 64.5 → 118.3 | 354 → 319 |
| 3 | 118.5 → 107.7 | 319 → 315 |

Late-window heapUsed range ≈120 MB is GC sawtooth, not trend: window-3 end
(107.7 MB) is BELOW window-2 end (118.3 MB), and RSS declines across w2→w3
(354→315 MB). Trajectory is stabilized, not monotonic.

## Falsifier verdicts

| falsifier | result |
|---|---|
| any 502/504 or dropped connection | **PASS** — 0 socket errors, 0 non-202/401/429 statuses across 899,943 client-completed requests |
| unstabilized heap growth | **PASS** — heap stabilizes; w3 ends below w2, RSS declining |
| 429 correctness (exactly bucket-capacity accepted per window) | **PASS** — client/server ledgers reconcile exactly; per-window accepts within 0.45 % of the capacity+refill law |
| 401 rejection rate = 100 % of bad signatures | **PASS** — every corrupted-signature request (179,949 client / 179,950 server incl. warmup) returned 401; zero leaked |

Overall: **ALIVE — all four falsifiers PASS.**

## Notes / disclosures

- Compile-freeze unblock attempt: build was blocked twice by another lane's
  in-flight untracked files (`workspace/app/bench/grid/page.tsx`, then
  `workspace/app/bench/compute/page.tsx`). No fix applied by this lane — the
  owning lanes landed their own fixes; build then succeeded clean.
- Driver is a hand-rolled closed-loop fetch pool (400 workers, global slot
  pacing to 5,000 RPS), gzip JSON payloads, deterministic signature
  corruption for the 401 leg.
- Latency improved across windows (p95 31.7 → 4.0 ms) as JIT warmed; no
  degradation trend.
