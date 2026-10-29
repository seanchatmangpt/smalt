# BENCH-7 — Pure-Erlang Actor Concurrency Ceiling

**Standing:** PASS (no ceiling reached through 32k processes; gentle degradation only)

Context: solo

## Subject

- Module: `/Users/sac/smalt/bench/bench_concurrency_ceiling.erl` (pure Erlang, raw `!` + receive ping/pong, NOT gen_server — the floor beneath PB-3's in-process face)
- Build: `MIX_BUILD_ROOT=_bench-ceil erlc -o bench/_bench-ceil/ebin bench_concurrency_ceiling.erl`
- Run: `erl -pa bench/_bench-ceil/ebin -noshell -s bench_concurrency_ceiling run -s init stop`
- Results: `/Users/sac/smalt/tmp/bench/court_bench_ceiling.jsonl` (6 rows: 1 meta + 5)

## Machine

```
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

## Method

For each N in {1k, 4k, 8k, 16k, 32k}: spawn N ponger processes, one warm round,
then R timed rounds (50/50/50/20/10 by N) of fan-out ping to all N and await all
pongs. Aggregate wall via `erlang:monotonic_time`, reductions via
`statistics(reductions)` delta over the coordinator.

## Results (actual output)

```
{"kind":"meta","module":"bench_concurrency_ceiling","n":null,"otp":"28","schedulers":16,"logical":16,"sweep_self_reds":19056823}
{"kind":"row","n":1000,"rounds":50,"round_trips":50000,"wall_ms":45,"usec_per_roundtrip":0.9,"reds_per_roundtrip":17.65338,"ops_per_sec":1111111.111111111}
{"kind":"row","n":4000,"rounds":50,"round_trips":200000,"wall_ms":207,"usec_per_roundtrip":1.035,"reds_per_roundtrip":18.4367,"ops_per_sec":966183.5748792271}
{"kind":"row","n":8000,"rounds":50,"round_trips":400000,"wall_ms":435,"usec_per_roundtrip":1.0875,"reds_per_roundtrip":23.468355,"ops_per_sec":919540.2298850574}
{"kind":"row","n":16000,"rounds":20,"round_trips":320000,"wall_ms":370,"usec_per_roundtrip":1.15625,"reds_per_roundtrip":44.104346875,"ops_per_sec":864864.8648648649}
{"kind":"row","n":32000,"rounds":10,"round_trips":320000,"wall_ms":377,"usec_per_roundtrip":1.178125,"reds_per_roundtrip":60.12288125,"ops_per_sec":848806.3660477453}
```

## Ceiling verdict

**No scheduler ceiling reached at N=32k.** Observed:

- Per-round-trip latency stays sub-2µs across the whole sweep: 0.90µs @1k →
  1.18µs @32k (+31%), aggregate throughput 1.11M → 0.85M ops/s (−24%).
- Reductions per round-trip grow ~3.4x (17.7 → 60.1) as fan-out width grows —
  the cost is scheduler coordination/queueing across 16 schedulers, not
  per-process overhead; wall stays flat from 16k→32k (370ms vs 377ms at equal
  round-trip count), indicating the sweep is still latency-bound, not
  capacity-bound.
- 32k processes is well below the default process_limit (262144); spawn cost
  was not the binding term. Consistent with PB-3's finding of no wall to L8192:
  the BEAM floor beneath the in-process face is ~1µs/round-trip and does not
  cliff in this range. A true ceiling, if any, lies beyond 32k processes or at
  scheduler saturation (16/16 busy) — not observed here.

Errors: none. All rounds completed; zero timeouts, zero lost pongs.
