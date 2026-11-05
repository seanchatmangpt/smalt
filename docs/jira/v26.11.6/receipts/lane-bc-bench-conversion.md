# LANE-BC receipt — bench-conversion (v26.11.6 wave+1, seeded early)

Standing: PARTIAL_ALIVE — benches executed for real this session; all three
fences pass, non-vacuity probe FAILed as designed.

## Subject

/Users/sac/smalt (canonical checkout, NO git actions by this lane).

## Owned diff (all additive)

NEW:
- bench/bench_bc_lane.erl — pure-Erlang bench lane: BC1 SASL kernel pair,
  BC2 ring/pool pair, BC3 produce/journal-floor pair + fetch absolute;
  calibration-then-fence (bc_fences.json written by calibrate, checked by
  run; fail-closed exit 1 on breach); extended JSONL receipt emission to
  docs/jira/v26.11.6/bench/bc.jsonl.
- bench/bench_bc_sink.erl — real ETS sink for the partition-worker deliver
  seam (Chicago: real state, not a mock).
- scripts/bench/bc_bench.sh — lane runner (erlc bench modules into
  _bc-laneBC/ebin; mix run --no-start --no-compile over the _build-laneKG
  beam set; calibrate|run modes).
- docs/jira/v26.11.6/bench/{BENCH.md, bc.jsonl, bc_fences.json}

ADDITIVE (existing files):
- bench/smalt_bench_court.erl — add_bc_targets/0 registration table
  (exported, smoke-verified via run_registered(<<"bc_sasl_plain_admit">>,
  100000) => 3.8M ops/sec; all 7 targets listed by list_targets/0).

## Commands + exits (this session, pinned toolchain asdf 1.20.4-otp-29)

- `MIX_BUILD_ROOT=_build-laneKG bash scripts/bench/bc_bench.sh calibrate`
  -> CALIBRATE PASS; fences: sasl 524.27 / ring 0.295 / log 3.49
  (measured ratios 52.4 / 0.59 / 0.35, headroom 10x / 0.5x / 10x).
- `... bc_bench.sh run` (x3) -> exit 0 PASS; last-run verdicts: sasl 51.8x
  (fence 524x), ring 1.17x (fence 0.295x min), log 0.69x (fence 3.49x max).
- Non-vacuity probe: fence bc_ring_pool_ratio_min inflated to 5.0 ->
  `run` exit 1 `BC FENCED RUN FAIL` -> fences file restored byte-exact
  (sha256 37208735...14f0a both sides).
- `python3 scripts/bench_framework_gate.py` -> PASS exit 0.
- `erlc bench/smalt_bench_court.erl bench/bench_bc_lane.erl` -> clean
  (zero warnings after export fix).
- Receipts on disk verified: bc.jsonl (7 rows + 3 fence verdicts, all
  re-read at use time), bc_fences.json, BENCH.md.

## Scoping disclosure

Loopback/single-host only. TARGET-UNMEASURED (in BENCH.md census):
restart-under-load (L2), GroupManager rebalance (L1), full-socket SASL
handshake, RDF projector batch latency (L16), admission fold-then-bisect
per-batch cost (L9), fetch scaling law.

## Cross-lane disclosures (both-receipt law)

- Read-only lease borrow of _build-laneKG beams: shared-tree mid-flight
  break in lib/smalt/aoq/arrow/flatbuf.ex refuses a fresh `mix compile`
  (SyntaxError at 715:1, witnessed in /tmp/bc-bench-compile.log). NOT
  repaired by this lane (foreign in-flight file, actively edited ~20:50);
  disclosed here for the owning lane and the coordinator.
- L8's kafka_vs_aoq_court + bench_aq_boundary_alloc untouched (conflict
  boundary honored).
