# Receipt — A-2: High-Contention Optimistic CAS (lane A-2, v26.10.14)

- **Date**: 2026-10-15
- **Subject**: `scripts/bench/a2_cas_contention.exs` (BEAM tier), `scripts/bench/a2_cas_contention.mjs` (SDK tier)
- **Data**: `docs/jira/v26.10.14/bench/a2-cas-contention.jsonl` (65 lines), `docs/jira/v26.10.14/bench/a2-cas-contention-sdk.jsonl` (21 lines)
- **Tier**: BEAM (`Smalt.Store.compare_and_swap/4`, `MIX_ENV=test mix run --no-start`) + SDK (`@azure/cosmos` `item.replace` If-Match against a dedicated smalt substrate, egress 39710, torn down after — port returns 000)

## Invariant: zero-phantom, exactly-one-winner

- BEAM: 20 rounds × N ∈ {10,100,1000} = 60/60 `round_proof` rows `"ok":true`; `grep -c '"ok":false'` on the JSONL → 0; `exactly_one_winner_per_round:true` on all three agg rows.
- SDK: 15/15 round rows `phantom_overwrites:0`; agg rows show exactly `winners == rounds` and `conflicts_412 == N*rounds - rounds` at every N.
- BEAM N=1000: 20,000 attempts → 20 winners, 19,980 conflicts (412 analog), 0 unexpected, 0 phantoms.
- SDK N=1000: 5,000 attempts → 5 winners, 4,995 × 412 PreconditionFailed, 0 unexpected, 0 phantoms.

A first BEAM run showed 2 phantom counters at N=100 and 19 at N=1000. Diagnosed as a **bench artifact, not an engine defect**: actors re-read the current value before CAS, so a straggler re-read the post-winner value and also won — the round window leaked. Fixed to fixed-base CAS (all actors race on the round's base etag, the true If-Match contention shape). The pre-fix data was discarded. Incidental finding: a read-then-CAS retry loop without re-arming on a fresh etag does NOT violate CAS atomicity — it silently advances the counter by more than one per round while every individual CAS is correct; monitoring must read the value, not count winners.

## Degradation table (BEAM tier, OTP 28, 16 schedulers, 20 rounds/leg)

| N | attempts/success | attempts/s | p50 µs | p95 µs | p99 µs | sched_busy_frac |
|---|---|---|---|---|---|---|
| 10 | 10.00 | 158,604 | 0.0 | 0.2 | 0.2 | 0.099 |
| 100 | 100.00 | 75,726 | 0.7 | 1.6 | 1.8 | 0.130 |
| 1000 | 1000.00 | 15,367 | 40.2 | 71.1 | 80.2 | 0.385 |

- Throughput degradation vs single-writer prior: b7 measured 282k/s single-writer CAS; at N=10 this lane holds ~159k/s (0.56×), collapses to ~15.4k/s at N=1000 (0.055×, a 10.3× throughput drop). Latency p50 degrades ∞→40 µs across N.
- `attempts_per_success == N` exactly: every attempt billed, one progress per N attempts — the Azure throttling-loop economics in miniature.
- Scheduler evidence: proc_runtime/wall/schedulers rises 0.099 → 0.385 with N — GenServer-serialized CAS keeps schedulers mostly idle-waiting (contention shows as queueing, not CPU burn).

## Wire-tier numbers (SDK, @azure/cosmos → smalt egress HTTP, 5 rounds/leg)

| N | winners | 412s | attempts/s | p50 ms | p95 ms | p99 ms |
|---|---|---|---|---|---|---|
| 10 | 5 | 45 | 2,538 | 2.4 | 5.0 | 5.2 |
| 100 | 5 | 495 | 4,188 | 18.4 | 23.9 | 25.9 |
| 1000 | 5 | 4,995 | 2,621 | 297.6 | 376.5 | 382.9 |

## Retry economics (the billed-retry analog)

- BEAM: ops-to-success at N=1000 = **1000.00 attempts per success** (19,980 of 20,000 attempts consumed zero-progress 412-analogs).
- SDK wire: **1000 attempts per success** at N=1000; 4,995 of 5,000 requests returned 412 — each one a consumed request unit that made no progress. At 1000-contention the wire handles ~2,600 req/s while 99.9% of them are 412s: a real Azure throttling loop would burn ~2,600 RU/s to make 2.6 wins/s.
- Wire latency degradation: p50 2.4 ms → 297.6 ms (124×) from N=10→1000; the winner pays the queue too.

## Falsifier status

`exactly_one_winner_per_round:true` and `phantom_overwrites:0` on all rows, both tiers. The invariant held everywhere it was asserted; no falsifier fired. The one earlier contradiction (first BEAM run) was traced to bench design and excluded with cause recorded.

## Boundary

- SDK tier runs against the local smalt Cosmos NoSQL plane, not live Azure — the 412 shape and per-attempt billing economics carry; absolute RU costs do not.
- BEAM tier uses fixed-base CAS per round; no backoff/jitter modeled (models the worst-case synchronous retry storm, intentionally).
- Wire agg throughput at N=100 (4,188/s) > N=10 (2,538/s) is per-connection HTTP keep-alive amortization at 500 vs 50 attempts, not a contention benefit.
- Post-run `database.delete()` cleanup returned 404 (container delete already cascaded); recorded, no data impact — all rounds read back before cleanup.
