# C-5 Receipt: ARM Control-Plane Saturation Storm

- **Lane**: C-5 (cross-product bench)
- **Script**: `scripts/bench/c5_arm_storm.py` (new, this lane)
- **JSONL**: `docs/jira/v26.10.14/bench/c5-arm-storm.jsonl` (row stamp `20261015T204338`)
- **Substrate**: anonymous self-booted, private ports 39850-39853, `:lro_delay_ms=250`, MIX_BUILD_ROOT `_build-c5`
- **SDK tier**: real `azure-mgmt-resource` track2, auth via smalt STS TokenCredential (py_arm_resources.py pattern)
- **Result**: C5 PASSED (all 4 phases, 0 client errors)
- **Date**: 2026-10-15

## Storm table

| Phase | Ops | Throughput | p50 / p95 / p99 (ms) | Verdict |
|---|---|---|---|---|
| P1 read storm (2000 mixed reads, 16 threads) | 2000 | 8,980.9 ops/s | 1.5 / 3.5 / 5.6 | clean (no errors) |
| P2 write+read mix (60 RG create-delete under 16-thread storm) | 60 writes + 20,194 reads | writes 23.65 ops/s; reads 7,960.6 ops/s | writes 310.6 / 345.7 / 361.8; reads 1.7 / 4.4 / 6.4 | write p50 degradation vs isolated baseline **0.97x (none)** |
| P3 LRO under load (50 storageAccount LRO PUTs + read storm) | 50 | 50/50 terminal | 285.9 / 305.7 / 305.7... p99 307.8 | **1.07x** vs B-6 isolated baseline 267.8 ms |
| P4 rate-limit burst (100 raw RG PUTs in 29 ms, 32 threads) | 100 | 3,448 writes/s instantaneous | 3.5 / 12.4 / 17.5 | **DIVERGENCE** |

## Phase detail

### P1 — read storm
Mixed 5-path reads (subscription get/list, resourcegroups list, providers
list, resources list). 1600x200 / 400x404. The 404s are exactly the
`GET /subscriptions/:sub_id/resources` path — **no such route exists in
`lib/smalt/arm_gateway/router.ex`** (verified by grep, 0 matches for
`get "/subscriptions/:sub_id/resources` while all four sibling routes
exist). Real Azure serves subscription-level resource listing; SDK
`client.resources.list()` would 404 against smalt. Divergence finding.

### P2 — write+read interference
Isolated write baseline (10 RG create+delete, no storm): p50 319.6 ms.
Under a 7,960 ops/s read storm: p50 310.6 ms → **0.97x, i.e. no measurable
control-plane interference at this scale** — smalt's gateway parallelism
absorbs concurrent reads+writes. Reads held p50 1.7 ms throughout.

### P3 — LRO under load
50 storageAccount LRO PUTs (real smalt LRO type) through SDK pollers while
the read storm ran. Poll-to-terminal p50 285.9 ms vs B-6 isolated 267.8 ms
→ **1.07x** — within noise of the isolated baseline. No degradation. NSG
synchronous-vs-LRO classification divergence from B-6 was NOT re-exercised
here (only storageAccounts, the true LRO type, were used).

### P4 — rate-limit probe
100 raw RG PUTs fired in **29 ms** (≈3,448 writes/s instantaneous, well
under 5 s). **All 100 answered `201 Created`, zero `429 TooManyRequests`,
no Retry-After headers.** Real Azure ARM throttles at this class
(control-plane is metered per-operation with write-quota limits; a 100-write
burst in <5 s is throttled with 429 + Retry-After). Smalt's ARM gateway has
no rate limiter → divergence finding, same class as B-6's classification
divergence: a client written against real Azure's throttle behavior
(retry-on-429) never exercises its retry path against smalt.

## Rate-limit verdict

**DIVERGENCE — no throttling.** smalt answers 100/100 201s to a 100-write
burst in 29 ms. Real Azure ARM would answer 429 TooManyRequests with
Retry-After. Any SDK/client retry-on-429 code path is untestable against
smalt as-is; adding a configurable rate limiter (e.g. per-scope write quota
answering 429 + Retry-After) would close this.

## Findings

1. **Rate-limit divergence (new, C-5)**: no 429 anywhere; smalt has no ARM
   control-plane rate limiter. `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`
   candidate.
2. **Missing route (new, C-5)**: `GET /subscriptions/:sub_id/resources`
   404s — subscription-level resource listing absent (verified in router
   source, line-level grep receipt above). `client.resources.list()` against
   smalt 404s; real Azure serves it.
3. **No interference (positive)**: writes under 8k ops/s read pressure show
   0.97x latency; LRO poll-to-terminal 1.07x isolated baseline. Gateway
   concurrency holds.

## Housekeeping

- Substrate down: ports 39850-39853 verified free (lsof empty) after run.
- `_build-c5` lane build root still on disk (rm denied by permissions in
  this lane's session) — coordinator to delete at integration per the
  cleanup law.
- No commits, no lib edits. Only files written: the bench script, the JSONL
  row, this receipt.
