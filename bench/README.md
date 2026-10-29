# bench — pure-Erlang benchmark suite

Contract: `docs/jira/v26.10.21/BENCH-ERLANG.md` (AR-BENCH-01..06). Landed
artifacts documented from disk 2026-10-21 (BENCH-12); nothing here is
aspirational. Receipts land in `tmp/bench/court_bench_*.jsonl` (scratch JSONL,
not indexed receipts).

## Core module — `smalt_bench_court.erl`

`bench/smalt_bench_court.erl` — pure Erlang, no Mix. `run_benchmark/3` runs a
zero-arity fun N times with aggregate `erlang:monotonic_time(nanosecond)` wall
clock and a `statistics(reductions)` delta taken around the loop, with the
loop owned by the harness (`do_n/2`) so reductions attribute to the bench body
(the PB-2 / IMPL-17 / GL-9 pattern). GC-stabilized `process_info(self(),
heap_size)` deltas fence heap claims (AR-BENCH-02, isolated-worker lineage
`t42_json.exs`). A `persistent_term` dispatch table (`add_target/3`,
`run_registered/2`, `list_targets/0`) lets later lanes register real-plane
targets without editing the core.

`court_selftest/0` is the fail-closed self-court: 3 stub benches over a real
ETS collaborator, row well-formedness validation, and a balanced-brace JSONL
parse of the emitted receipt. Exit 0 = PASS, exit 1 = FAIL. Witnessed PASS:
`tmp/bench/court_bench_20261021T223254.701Z.jsonl` (3 rows, reds_per_op
0 / 8.002 / 20).

## Per-plane harnesses

Each harness is a standalone `.erl` compiled with `erlc` (no Mix in the hot
path). Build/run commands live in the file header comments.

| plane | module | subject | output (tmp/bench/) |
|---|---|---|---|
| cosmos | `bench_cosmos_cas.erl` (BENCH-3) | 10k serial point-reads, raw TLS `:9444` twin, STS bearer, isolated worker; loud SKIP exit 3 when substrate is down, never restarts it | `court_bench_cosmos.jsonl` |
| amqp | `bench_amqp_frame.erl` (BENCH-4) | 100k decodes of one 1582-byte AMQP transfer frame via the Mix-built `'Elixir.Smalt.Amqp.FrameCodec'` beam loaded by code path (erlc cannot compile the Elixir sources; documented choice) | `court_bench_amqp.jsonl` |
| powl | `bench_powl_pipeline.erl` (BENCH-5) | 5000 post-fix 4-step settlement orchestrations through the pure-Erlang FOND/POWL runner, isolated worker with file group leader so the gen_statem termination report stays inside the timing window | `court_bench_powl.jsonl` |
| json | `bench_json_streaming.erl` (BENCH-6) | native `:json` SAX streaming (`decode_start/3` + `decode_continue/2`) over a deterministic ~50 MB synthetic Cosmos-style corpus | `court_bench_json.jsonl` |
| ceiling | `bench_concurrency_ceiling.erl` (BENCH-7) | actor ping round-trip sweep n=1k→32k, wall + reductions per round-trip | `court_bench_ceiling.jsonl` |

## escript runner — PENDING-BENCH-1

AR-BENCH-05 requires `scripts/bench/erlang_bench.escript` (plain escript,
main/1, lane name from argv, one JSON line per row, hyphenated filenames per
`scripts/bench/lib.sh`). Not landed. Bounded-poll result: absent after a
20-minute poll of `bench/` + `scripts/bench/` on 2026-10-21, while the five
plane harnesses landed mid-poll (15:34) and their outputs landed at
15:40–15:42. This token names the open gap; it disappears only with a closing
receipt.

## Receipts schema

Core rows (`court_bench_<rfc3339ts>.jsonl`): `name`, `n`, `wall_ms`,
`ops_sec`, `ns_per_op`, `reds_per_op`, `heap_delta` — all numeric except
`name`, validated by the self-court (`?FIELDS`). Per-plane lanes emit
lane-specific rows keyed on `lane` / `surface` / `op`:

- cosmos: `ops_per_sec`, `p50_ms`, `p95_ms`, `p99_ms`, `errors`,
  `worker_reductions`, `wall_ms`, `machine`
- amqp: `frame_bytes`, `best_reductions`, `reds_per_frame`, `us_per_frame`,
  `errors`, `machine`
- powl: `agg_wall_ms`, `reds_per_op` (total-work, caller+gen_statem),
  `heap_delta_words`, `min_ms`/`max_ms`, `warmup`
- json: `corpus_bytes`, `docs`, `peak_heap_bytes`,
  `heap_gate_le_2mb`, `wall_gate_le_100ms`, `verdict`
- ceiling: meta row (`schedulers`, `sweep_self_reds`) + `kind:"row"` entries
  (`usec_per_roundtrip`, `reds_per_roundtrip`, `ops_per_sec`)

## Cross-language denominator table

Elixir-harness number vs pure-Erlang court number per plane. This table is the
BENCH-12 deliverable. All values re-read from the on-disk artifacts at
document time (no-overclaiming: counts re-read at use time).

| plane | Elixir-harness number | pure-Erlang court number | verdict |
|---|---|---|---|
| cosmos point-read | T43 wire p99 0.813–1.04 ms fence (`docs/jira/v26.10.21/VALIDATION.md` AR-POWL-PERF) | p99 0.543 / 0.672 ms across 2 runs, 10k ops each, 2,130–2,251 ops/s, 0 errors (`court_bench_cosmos.jsonl`) | PARITY — inside the 2x fence (p99 ≤ 2.08 ms) |
| amqp frame decode | 254.3 reds/frame (IMPL-13/17 denominator, `receipts/impl13-jit-2912.md`; live `impl17-amqp-reductions.jsonl` shows 268.2–268.4 on the 87B–64KB classes) | 254.5 reds/frame, 1.05 µs/frame on the 1582-byte IMPL-13 shape, 0 errors (`court_bench_amqp.jsonl`) | PARITY — Δ 0.08% vs 254.3 |
| powl orchestration | PB-2 stage-composed ≈17.5k reds / 8-step orchestration (≈1,609 reds/step) (`receipts/pb2-reductions-denominator.md`); PB-5 gate A caller-side: Erlang runner 239.31 vs Executor 964.31 reds/step (`receipts/pb5-crosslang-differential.md`) | BENCH-5 post-fix: 45,182.7 total-work reds/4-step op (≈11.3k/step), p50 0.305 ms, 3,222.3 ops/s, 0 errors (`court_bench_powl.jsonl`) | TYPED DIVERGENCE — accounting scope: PB-2 counts stage-composed caller-attributed reds on an 8-step plan; BENCH-5 counts total reds of the spawned gen_statem (child work + seal), so the numbers answer different questions, not a perf contradiction |
| json decode | IMPL-16 native `:json` full decode: 134.2 ms min-of-5 on 205.5 MB corpus, OTP 29.1.2 (`receipts/impl16-json-string-bench.md`) | BENCH-6 SAX stream: 80 ms min on 52.7 MB corpus, peak heap 38,504 B, both gates PASS (`court_bench_json.jsonl`) | TYPED DIVERGENCE — different corpora (205.5 vs 52.7 MB) and modes (full decode vs SAX stream); no same-corpus differential run exists |
| governance tax (GL-9) | 47.24 reds/step, 0.25 µs/step tax (`tmp/bench/gl9-governance-tax.jsonl`, Elixir harness `scripts/bench/gl9_governance_tax.exs`) | none — no pure-Erlang court for the GL-9 differential landed | TYPED DIVERGENCE (missing court) — PENDING-BENCH-2 |
| actor ceiling | no Elixir-side denominator (plane is pure-Erlang-only) | 17.65–60.12 reds/round-trip across n=1k→32k, ~0.9–1.18 µs/round-trip (`court_bench_ceiling.jsonl`) | n/a — pure-Erlang baseline |

## Open tokens

- PENDING-BENCH-1: `scripts/bench/erlang_bench.escript` (AR-BENCH-05) — not
  landed; 20-min bounded poll negative on 2026-10-21.
- PENDING-BENCH-2: GL-9 pure-Erlang court leg (the 47.24 reds/step tax has no
  cross-language court number).

## See Also

- `docs/jira/v26.10.21/BENCH-ERLANG.md` (AR-BENCH-01..06 contract + Status)
- `scripts/bench/REGISTRY.md`, `scripts/bench/lib.sh`
- `docs/NO_SLEEP_DOCTRINE.md` (ratio-fence law)
- `docs/jira/v26.10.21/VALIDATION.md` (T43 / PB-2 / PB-5 rows)
