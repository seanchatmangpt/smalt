# BENCH-3 — court_bench_cosmos (pure Erlang bulk CAS point ops, raw TLS :9444)

**Standing: PASS (two consecutive green runs, 0 errors, fence met with headroom — measured p99 0.543/0.672 ms vs the 2.08 ms parity fence, i.e. under the T43 wire p99 itself)**

- Lane: `court-bench-cosmos` (BENCH-3)
- Module: `/Users/sac/smalt/bench/bench_cosmos_cas.erl` (pure Erlang, `:ssl` + bit-syntax, zero Elixir — the ECOURT pattern from `test/courts/court_wire.erl` leg 2)
- Build: `MIX_BUILD_ROOT=_bench-cosmos`, `erlc -o _bench-cosmos/ebin bench/bench_cosmos_cas.erl` (exit 0; one cosmetic warning: unused `Ssl` in `need/5` base clause)
- Result file: `/Users/sac/smalt/tmp/bench/court_bench_cosmos.jsonl` (2 rows, run-1 + run-2)
- Substrate: live boot (beam pid 85369), :9444 LISTENING preflighted with lsof; lane never restarts the substrate
- Context: solo

## Parity table (sanity fence vs T43)

T43 wire point-read p99 0.813–1.04 ms (docs/jira/v26.10.21/VALIDATION.md row AR-POWL-PERF, lane powlbench compare rows). Parity fence = 2x upper = **2.08 ms**.

| Harness | n | p50 (ms) | p95 (ms) | p99 (ms) | ops/s | errors |
|---|---|---|---|---|---|---|
| T43 wire fence (reference) | — | — | — | 0.813–1.04 | — | 0 |
| BENCH-3 run 1 (this lane) | 10000 | 0.437 | 0.482 | **0.543** | 2251.4 | 0 |
| BENCH-3 run 2 (this lane) | 10000 | 0.441 | 0.551 | **0.672** | 2130.0 | 0 |

Parity: within 2x as expected — in fact better than the reference p99 on the same subject (different harness: serial keep-alive point-reads in an isolated worker, per-op `erlang:monotonic_time/1` microsecond stamps; parent measures aggregate wall + worker reductions delta: ~653/op both runs).

## Machine (from `just bench-machine`)

{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}

## Commands

```bash
export MIX_BUILD_ROOT=_bench-cosmos
mkdir -p _bench-cosmos/ebin
erlc -o _bench-cosmos/ebin bench/bench_cosmos_cas.erl
export BENCH_MACHINE="$(just bench-machine)"
erl -noshell -pa _bench-cosmos/ebin -eval 'bench_cosmos_cas:main()' -s init stop
# run 1: EXIT=0, run 2: EXIT=0 (consecutive, same boot)
```

Loud SKIP path exercised by construction (lsof preflight on :9444; `skip` -> exit 3, never restarts). Not witnessed this session because the substrate was up for every attempt.

## Honest notes

- The first three run attempts failed on harness bugs (parse_head status split, `{ok, Ssl} = tls_conn()` mismatch — `tls_conn/0` already unwraps), fixed in-lane; the two green runs above are post-fix consecutive runs on the same substrate boot.
- Compile warning is residual/cosmetic.
- Result rows carry extra fields (`worker_reductions`, `wall_ms`) beyond the lane schema — additive, kept for the reductions receipt.
