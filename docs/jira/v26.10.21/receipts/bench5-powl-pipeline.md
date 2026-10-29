# BENCH-5 — In-Process Erlang POWL Pipeline Bench (smalt_fond_powl_runner)

Context: solo
**Standing:** ALIVE

- **Date**: 2026-10-21
- **Lane**: bench5 (bench)
- **Module**: `/Users/sac/smalt/bench/bench_powl_pipeline.erl` (pure Erlang, erlc OTP 29.1.2, beams in `/Users/sac/smalt/_bench-powl/ebin`)
- **Result file**: `/Users/sac/smalt/tmp/bench/court_bench_powl.jsonl` (1 row, lane-local only)
- **Subject**: `lib/smalt/pipeline/smalt_fond_powl_runner.erl` — direct in-process MFA `run/1`, N=5000 4-step settlement orchestrations (linear plan `sttl_open→sttl_capture→sttl_move→sttl_close`, deterministic contingency, single-sender post-fix completion protocol)
- **Toolchain**: asdf erlang 29.1.2 (PB-5's pinned OTP), direct erlc (no mix); lane build root `/Users/sac/smalt/_bench-powl/`
- **Machine (just bench-machine, ambient PATH)**: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}` — the lane itself ran on asdf OTP 29.1.2 to match PB-5's pin; disclosed divergence from the ambient bench-machine block.

## Commands

```
$ export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH"
$ erlc -o _bench-powl/ebin lib/smalt/pipeline/{smalt_fond_plan,smalt_fond_seal,smalt_fond_powl_runner}.erl bench/bench_powl_pipeline.erl
$ erl -pa _bench-powl/ebin -noshell -eval 'bench_powl_pipeline:main().' > tmp/bench/bench5-run.log 2>&1
$ echo $?
0
--- BENCH5 n=5000 ok=5000 errors=0 agg_wall_ms=1551.7 ops_per_sec=3222.3
--- BENCH5 p50_ms=0.305 p95_ms=0.340 p99_ms=0.425 reds_per_op=45182.7 heap_delta_words=317811
```

```jsonl
{"lane":"bench5","surface":"erlang_powl_runner_postfix","op":"settlement_orchestration_4step","n":5000,"ops_per_sec":3222.3,"p50_ms":0.305,"p95_ms":0.340,"p99_ms":0.425,"errors":0,"machine":{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"otp":29,"darwin":"26.2"},"agg_wall_ms":1551.7,"wall_sum_ms":1550.6,"reds_total":225913258,"reds_per_op":45182.7,"heap_delta_words":317811,"min_ms":0.286,"max_ms":0.650,"warmup":100}
```

## Parity verdict vs PB-5 gate table (typed)

- **Post-fix protocol PARITY (same order of magnitude, no new divergence)**:
  p50 0.305 ms vs PB-5 post-fix 0.456 ms (1.5x faster); ops/s 3222.3 vs
  2117.5 (1.52x). Same machine, same protocol cost shape. The residual
  delta is attributed (typed, not fixed): PB-5 drove 16-step plans through
  `mix run` under the full repo release; this lane drives 4-step plans as
  bare-erlc beams, so less logger-render + load machinery sits in the
  window. n=5000 vs n=200 also narrows the tail (p99 0.425 vs 0.609 ms).
- **vs the PRE-fix table (p50 0.001 ms, 104k ops/s)**: TYPED DIVERGENCE,
  expected and re-confirmed independently at 25x the sample size — the
  single-sender `{stop, {completed, Receipt}}` protocol pays one
  gen_statem termination error report per run (logger render through the
  caller's group leader inside the timing window; `bench5-run.log` holds
  the 5100-report evidence). The post-fix numbers never return to the
  pre-fix 104k-ops/s regime; that regime existed only because the
  pre-fix protocol raced (98/200 misreported successes as crashes).
- **Reductions**: caller reds/op 45,182.7 for a 4-step plan (11,295.7
  per step) vs PB-5 post-fix 3,097.31/step at 16 steps — higher per-step
  because this caller reds delta includes the two per-op
  `monotonic_time` calls and the synchronous group-leader report render,
  which PB-5's per-step accounting did not carry. Not directly comparable
  as a per-step metric; reported honestly as aggregate.
- **Heap delta**: +317,811 words caller heap over 5000 ops (post-GC
  residual ~63 words/op) — the caller accumulates the per-op result
  tuples and sorted latency list; no leak shape (bounded, GC-reclaimed).

## Standing

ALIVE for the measured claim: 5000/5000 successful orchestrations, 0
errors, post-fix completion protocol parity with PB-5's re-measured gate
table (no new divergence), pre-fix throughput regime confirmed gone (the
dominant cost is the per-run termination report, a real protocol cost,
disclosed not fixed). PARTIAL for promotion: same PB-5 conclusion holds —
the per-run report cost keeps the runner out of the pre-fix perf regime
until the owning lane changes the exit-reason protocol.

## Integrity re-check (CTXFILL-2, 2026-10-21)

Cited artifacts re-read from disk (fresh output, no re-run needed — the
jsonl row and the 5100-report log are the receipt's own evidence):

```
$ ls -l tmp/bench/court_bench_powl.jsonl tmp/bench/bench5-run.log
-rw-r--r--@ 1 sac  staff      418 Oct 21 15:41 tmp/bench/court_bench_powl.jsonl
-rw-r--r--@ 1 sac  staff  3096851 Oct 21 15:41 tmp/bench/bench5-run.log
exit 0
$ sha256sum tmp/bench/court_bench_powl.jsonl
45ba7e736b8c20e1e47056838910b360b8874f27d0715b7e93e5e42dfb549d43  tmp/bench/court_bench_powl.jsonl
$ python3 -c "import json;[print(r['lane'],r['n'],r['ops_per_sec'],r['errors']) for r in map(json.loads,open('tmp/bench/court_bench_powl.jsonl'))]"
bench5 5000 3222.3 0
exit 0
$ grep -c "BENCH5" tmp/bench/bench5-run.log
3
exit 0
```

Cited jsonl matches the receipt's headline numbers exactly (n=5000,
3222.3 ops/s, 0 errors); the run log is present with BENCH5 markers.
Standing unchanged: ALIVE for the measured claim.
