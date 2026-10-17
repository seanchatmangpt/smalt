# LC-1 Receipt — 8-Hop Cloud-Chain Tax Pipeline (lifecycle harness)

- **Lane**: LC-1 on `/Users/sac/smalt` (canonical checkout)
- **Date**: 2026-10-15 (run at 2026-10-16T04:36Z)
- **Harness**: `scripts/bench/lifecycle_harness.mjs` (self-boots smalt substrate on ports 39640-39644, MIX_ENV=test anonymous, plus `next start` workspace server on 39650 for hop 2)
- **JSONL**: `docs/jira/v26.10.14/bench/lifecycle-8hop.jsonl` (11 rows: 8 hop rows + e2e + kd-absent + cost-ledger-1M)
- **Machine**: Apple M3 Max, 16 cores, 48 GB, Node v26.10.0, Darwin 25.2.0

## ALIVE witness

200/200 complete lifecycle cycles executed against real smalt surfaces
(~1,600 API ops; 8 sequential hops per cycle), **0 transport or semantic
errors**, and hop-8 synchronous read-your-write verified **200/200** —
ingested row read back by KQL `where TxId == '<tx>' | take 1` in the same
cycle. Run completed in ~2.7 s wall.

## Hop table (per-hop latency, ms; N=200 each)

| Hop | Cloud-Chain | smalt surface (mapping) | p50 | p95 | p99 | ops/s | err |
|---|---|---|---|---|---|---|---|
| 1 Entra auth | STS `POST /oauth2/v2.0/token` — **REAL** | 0.804 | 2.359 | 3.956 | 1244/s | 0 |
| 2 APIM | workspace `next start` `/api/v1/ingest` (token-bucket rate limiter) — **NEAREST_ANALOG** | 1.581 | 3.410 | 4.975 | 632/s | 0 |
| 3 Cosmos CAS | `@azure/cosmos` create + **ifMatchEtag replace** (pk `/pk`) — **REAL** | 1.585 | 4.635 | 7.651 | 631/s | 0 |
| 4 KV/HSM sign | KV crypto `POST /keys/lc1-tax-key/sign` RS256 (arm_tls 39644, self-signed) — **REAL** | 2.151 | 4.133 | 4.749 | 465/s | 0 |
| 5 EH ingress | `@azure/event-hubs` producer, 1 event/send (AMQP), 2 partitions — **SDK** (directive's REST `/messages` does not exist in smalt) | 0.565 | 2.038 | 3.568 | 1770/s | 0 |
| 6 Blob journal | block-blob **PUT** to `compliance-lc1` container — **PUT-journal** (no append surface) | 0.874 | 2.407 | 3.315 | 1144/s | 0 |
| 7 Search | Resource Graph `project id, name, type` over seeded storage account — **NEAREST_ANALOG** | 0.847 | 2.041 | 3.252 | 1180/s | 0 |
| 8 Sentinel RYW | DCR ingest (1 row, 204) + KQL `where TxId | take 1` read-back, row verified — **REAL** | 1.640 | 4.175 | 10.315 | 610/s | 0 |

## End-to-end distribution (N=200 cycles)

| metric | value |
|---|---|
| p50 | 11.146 ms |
| p95 | 23.293 ms |
| p99 | 31.894→31.994 ms (JSONL: 31.994) |
| mean (1/p50 rate) | ~11.1 ms/cycle (~89.7 cycles/s) |
| cycles completed / requested | 200 / 200 |
| sentinel RYW verified | 200 / 200 |
| errors (all hops) | 0 |

## KD-absent list

| KD | Hop | Finding |
|---|---|---|
| KD-APIM-ABSENT | 2 | No APIM gateway surface in smalt; used the N-4 lane's `workspace/app/api/v1/ingest/route.ts` Next handler (landed; HMAC + token-bucket) as labeled nearest-analog gateway policy. |
| KD-APPEND-ABSENT | 6 | No append-blob surface in `blob_storage.ex`/`blob_service.ex`; block-blob PUT to a compliance container used as the journal (PUT-journal, labeled). |
| KD-SEARCH-ABSENT | 7 | No Cognitive Search surface in smalt; Resource Graph query (c6-witnessed `project` form) over a seeded storage account used as labeled nearest-analog. |
| KD-REST-EH-ABSENT |  | The directive's EH REST `/messages` does not exist in smalt; `@azure/event-hubs` AMQP producer used (SDK class, post-KD-18/19/20). |
| KD-LC1-SUBSTRATE-CRASH (candidate) | — | One of two full-run attempts crashed mid-run: `Smalt.Telemetry.RollingCounters.bump` (`lib/smalt/telemetry.ex:210`) raised badarg in `:ets.update_counter` on key `{minute, {:bandit_request_stop, "/oauth2/v2.0/token", 200}, :self}`, taking the beam down. Pre-existing substrate defect (telemetry, not lifecycle path); not reproduced on the second full run (200/200 clean). Candidate for v26.10.15. |

## Cost ledger — 1M-cycle extrapolation

Published list rates, **as-of-knowledge 2026-10, not a quote**:

| hop | rate | per cycle |
|---|---|---|
| 2 APIM | $3.50/1M calls | $0.0000035 |
| 4 KV sign | $0.03/10k RSA-2048 sign | $0.0000030* |
| 5 EH | $0.028/1M events | $0.000000028 |
| 6 Blob put | $0.05/10k writes | $0.0000050 |
| 8 Sentinel | $4.30/GB analytic ingest (~500 B/row) | $0.00000215 |
| 1 Entra token | free tier | $0 |
| 3 Cosmos | RU-based — excluded (throughput-mode dependent) | — |
| 7 Search | ABSENT — not costed | $0 |
| **total** | | **$0.0000687/cycle → ~$68.65 per 1M cycles** |

(*KV Premium sign rate $0.03/10k = $0.000003; harness JSONL stores $0.00003 —
conservative 10x. JSONL is the machine record.)

## Honesty notes

- Mapping labels ride every JSONL row (`mapping` field): REAL / NEAREST_ANALOG / SDK / PUT-journal.
- Hop 2 runs the real N-4 handler in a real `next start` server (built .next), HMAC-signed, 202-verified.
- Hop 4 sign round-trip verified (RS256 over sha256 of the tax record payload; `value` returned).
- Hop 8 verification is semantic: the read-back row must contain the cycle's TxId, not just a 200.
- Warmup: 5 warmup cycles excluded from all statistics.
- KV key/db/DCR/storage-account seeding happens before the measured loop; seeding is not counted in per-hop stats.
- KV sign cost rate discrepancy noted above (JSONL $0.00003 vs receipt $0.000003); JSONL row `op=cost-ledger-1M` holds `kv_sign_hop4: 0.00003` — flagged, JSONL is the record of what the run emitted.

## Commands

```
node scripts/bench/lifecycle_harness.mjs   # LC1_N env, default 200
```

Ports 39640-39650 released after run (verified via lsof). No lib edits, no commits.

## Re-witness 2026-10-16 (v26.10.16 DoD lane, SUSPECT clear)

- **Standing**: ALIVE — SUSPECT triage receipt command-output requirement satisfied by this run.
- **Command**: `MIX_BUILD_ROOT=_build-lane322 node scripts/bench/lifecycle_harness.mjs` (repo `/Users/sac/smalt`)
- **JSONL**: `docs/jira/v26.10.16/bench/lifecycle-8hop.jsonl` (11 rows, mirrored from the harness's own `docs/jira/v26.10.14/bench/lifecycle-8hop.jsonl`, which this run refreshes in place)
- **Rendered**: v26.10.16 `BENCH_RESULTS.md` — all 9 op rows (hop1..hop8 + e2e cycle) present, 0 errors on every row.
- **Machine**: Apple M3 Max, 16 cores, 48 GB, Elixir 1.19.5, OTP 28, Darwin 26.2 (`just bench-machine` output, 2026-10-16)

| op | n | ops/s | p50 | p95 | p99 | err |
|---|---|---|---|---|---|---|
| hop1 sts | 200 | 2240 | 0.446 | 0.603 | 0.942 | 0 |
| hop2 next-ingest | 200 | 1238 | 0.808 | 1.204 | 1.619 | 0 |
| hop3 cosmos-cas | 200 | 1167 | 0.857 | 1.061 | 1.410 | 0 |
| hop4 kv-sign | 200 | 645 | 1.550 | 1.821 | 2.056 | 0 |
| hop5 eventhubs | 200 | 3080 | 0.325 | 0.423 | 0.536 | 0 |
| hop6 blob-journal | 200 | 2387 | 0.419 | 0.568 | 0.777 | 0 |
| hop7 resource-graph | 200 | 2426 | 0.412 | 0.593 | 0.863 | 0 |
| hop8 sentinel-ryw | 200 | 1163 | 0.860 | 1.071 | 1.196 | 0 |
| e2e cycle | 200 | 176 | 5.669 | 7.762 | 8.545 | 0 |

cycles 200/200, sentinel RYW verified 200/200, 0 errors, cost ledger $41.65/1M cycles.

### Boot attempts before the clean run (honest log)

1. Attempt 1 (15:51Z): failed at boot — transient port collision on 39643/39644 with a
   concurrent lane's private substrate (beam exited on its own moments later; not evicted,
   port law respected). Its log showed `:eaddrinuse` on a Bandit listener.
2. Attempt 2 (15:56Z): failed at boot — shared lib
   `lib/smalt/messaging/amqp/connection.ex` did not compile (`defp settle/2` vs `settle/3`
   defaults), mid-edit by its owning lane. **No unblock fix applied by this lane**; the
   owning lane landed its fix minutes later and my lane build root compiles clean
   (warning only, connection.ex:1444). Compile-freeze duration ~3 min, self-resolved.
3. Attempt 3 (15:59Z): clean end-to-end run above; ports 39640-39650 verified released
   after teardown.

Shared infra untouched: no edits to scripts/bench/lib.sh, REGISTRY.md, 15-bench.just, or
the harness itself. Lane build root `_build-lane322` left in place for the coordinator
(`just lane-clean` reclaims).
