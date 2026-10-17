# Receipt — a1 change-feed lane re-run (v26.10.16 refresh in place)

- **Subject:** `/Users/sac/smalt` @ main working tree, lane a1 (`scripts/bench/a1_change_feed.exs`)
- **Standing:** PASS (baseline + stall rows, errors:0; stderr teardown-race noise noted below)
- **Date:** 2026-10-16
- **Machine:** `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}` (`just bench-machine`)
- **Result file (refreshed in place, 2 rows):** `docs/jira/v26.10.16/bench/a1-change-feed.jsonl`
  (prior 4-row content snapshotted to `/tmp/a1-v161016-previous.jsonl`)
- **Build:** `MIX_BUILD_ROOT=_build-lane348`, MIX_ENV=test, `--no-start`, private port block
  39190–39195 via `SMALT_TEST_*_PORT` (default listeners held by substrate pid 882 — lane
  pre-flighted with lsof, no eviction).

## Command (unedited)

```
$ MIX_ENV=test MIX_BUILD_ROOT=_build-lane348 \
  SMALT_TEST_ARM_PORT=39190 SMALT_TEST_EGRESS_PORT=39191 SMALT_TEST_AMQP_PORT=39192 \
  SMALT_TEST_EVENT_HUBS_PORT=39193 SMALT_TEST_ARM_TLS_PORT=39194 SMALT_TEST_MCP_PORT=39195 \
  A1_RESULT_FILE=docs/jira/v26.10.16/bench/a1-change-feed.jsonl \
  mix run --no-start scripts/bench/a1_change_feed.exs
```

## Results

| op | n | p50 | p95 | p99 | errors | window_s |
|---|---|---|---|---|---|---|
| baseline | 2000 | 31.0 ms | 311.0 ms | 381.0 ms | 0 | 1.375 |
| stall | 2000 | 1755.0 ms | 3421.0 ms | 3636.0 ms | 0 | 3.846 |

## Delta vs prior runs (e2e upsert→archived, baseline op)

| metric | v26.10.14 | v26.10.16 prior (36/359/444) | this run | vs v26.10.16 prior | vs v26.10.14 |
|---|---|---|---|---|---|---|
| e2e p50 | 21.0 ms | 36.0 ms | 31.0 ms | −13.9% | +47.6% |
| e2e p95 | 96.0 ms | 359.0 ms | 311.0 ms | −13.4% | +224.0% |
| e2e p99 | 133.0 ms | 444.0 ms | 381.0 ms | −14.2% | +186.5% |

Stall op: 1755/3421/3636 vs v26.10.16 prior 1724/3149/3357 (+1.8/+8.6/+8.3%) and
v26.10.14 1560/2755/2771 (+12.5/+24.2/+31.2%). Same ordering as prior runs; stall
window remains latency-dominated by the injected 200 ms commit delay.

## Disclosure

- stderr carried an archiver crash trace ("archiver stopped at seq 2980") from the
  known drain-vs-`:init.stop` teardown race in `archiver_loop` — both phase rows were
  already emitted with `n=2000, errors:0` at that point; no in-phase data loss. Noted,
  not repaired from this lane.
- The v26.10.16 rows on disk continue to carry the full `stages_per_s` breakdown, so
  the stage-level delta the aggregate flagged as not-computable for the earlier
  v26.10.16 run is computable for this refresh.
