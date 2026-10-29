# SQLD-8 — Bulk-Ingest Perf Baseline (100k-row dump → OCEL projection)

**Standing:** PASS
Context: solo · Date: 2026-10-21 · Lane: SQLD-8 · Milestone: v26.10.21

## Subject

- Harness: `/Users/sac/smalt/scripts/bench/sqld8_ingest_baseline.exs` (worker, plain `elixir`, no Mix) + `/Users/sac/smalt/scripts/bench/sqld8_ingest_baseline.sh` (driver, isolated workers under `/usr/bin/time -l`)
- Results: `/Users/sac/smalt/tmp/bench/sqld8-ingest-baseline.jsonl` (2 rows, errors=0)
- Artifacts: `/Users/sac/smalt/tmp/sqld8/` (100k-row pg COPY dump `events_dump.sql` 4,231,918 bytes, `events_direct.csv`, 3+3 round DBs and round logs)

## Method (AR-BENCH-01 aggregate model)

Wall via `:erlang.monotonic_time(:millisecond)` deltas in an isolated worker
OS process (plain `elixir`, no Mix in the hot path, AR-BENCH-05); paired
rounds, min-of-3; `errors=0`. Peak memory = worker OS max-RSS
(`/usr/bin/time -l`; macOS reports bytes). `:erlang.memory/0,1` and
`:erlang.statistics(:reductions)` not used (AR-BENCH-01/02 ban). No fixed
sleeps anywhere in the harness (no-sleep doctrine).

## Corpus

Deterministic LCG seed 20261021, SQLD-3 corpus schema scaled:
`events(event_id, ts, activity, object_id, temp, duration)`, 200 objects,
100,000 rows, pg_dump COPY text format.

## Routes measured (both landed)

- **converter**: `Smalt.SqlIngest.parse_dump` → `to_csv` → duckdb CLI
  `INSERT … read_csv_auto` into `ocel_events` + `activity_aggregate`
  projection (per-activity COUNT/SUM/AVG/MAX — the AR-BENCH-01 aggregate
  model) + aggregate CSV export.
- **direct** (denominator floor, no parse step): duckdb `read_csv_auto` on
  the same rows, identical projection.

## Results (min-of-3, M3 Max, OTP 28)

| route | min wall | rows/sec | peak RSS (worker) |
|---|---|---|---|
| converter (dump→projection) | 1545 ms | 64,725 | 294,191,104 B (280.6 MiB) |
| direct (csv→projection) | 222 ms | 450,450 | 100,024,320 B (95.4 MiB) |

Full rows (p50/p95/p99, rounds_ms) in the jsonl. Zero errors across 6 rounds.

## Correctness legs (real output, all passing)

1. Row counts exact: `ocel_events` = 100,000 in BOTH routes' DBs.
2. Cross-route aggregate parity: `activity_aggregate` conv vs direct byte-identical (`diff` empty).
3. Source parity: aggregate recomputed from the source corpus by independent
   awk over `events_direct.csv` equals the duckdb projection
   (`SOURCE-PARITY dump->projection: EXACT`): convey 33377/500909901/7.5062/15.0,
   freeze 33226/498075930/7.5014/15.0, palletize 33397/501097801/7.4942/15.0.

## Fence derivation (from the measured baseline, not invented)

- Observed round spread, converter: 1545–2067 ms (±29% machine variance).
- **Fence: 100k-row converter-route ingest ≤ 30 s.** Derivation: 30,000 ms /
  1545 ms min-of-3 = **19.4× headroom** over the measured denominator — far
  outside the observed ±29% round spread, so the fence trips only on a real
  regression (not CI noise), while still bounding a production ingestion
  path two orders of magnitude tighter than nothing.
- **Fence: direct route ≤ 10 s** (45× headroom over 222 ms min).
- **Fence: worker peak RSS ≤ 512 MiB** (1.82× headroom over measured 280.6 MiB).
- Per AR-BENCH-06 the long-term CI form of this fence is a ratio fence
  (measured vs re-run baseline, paired rounds); the absolute budgets above are
  the production targets typed from this baseline. Any future fence claim
  re-runs `scripts/bench/sqld8_ingest_baseline.sh` and re-derives.

## Machine

`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
(matches `just bench-machine`). Honest notes: (1) the dispatch said OTP-29;
this machine runs **OTP 28** — recorded as-is. (2) DuckDB CLI v1.4.1 (Andium)
b390a7c376. (3) Results land in `tmp/bench/` per lane dispatch, not the
v26.10.14 bench registry directory (this is not a port-law a/b/c/n lane; no
substrate booted, no ports held).
