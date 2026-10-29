# BENCH-8 — bin/court-bench escript runner + `just court-bench` recipe (v26.10.21)

**Standing: PASS** (runner wiring ALIVE on the documented-interface fallback;
Context: solo
run_all/0 dispatch wired and dormant)

## Scope delivered

1. **`/Users/sac/smalt/bin/court-bench`** — escript runner (OTP-29 toolchain,
   `/opt/homebrew/opt/erlang@29/bin`). Compiles `bench/*.erl` by shelling out
   to `erlc` (via `open_port`; `compile:files/2` is not resolvable inside the
   escript runtime, so the mandated erlc path is a subprocess) into the
   lane-private build root `_bench-escript/ebin`, then dispatches:
   - `smalt_bench_court:run_all/0` if exported (the BENCH-2 contract; wired,
     dormant — see Interface timing below);
   - otherwise the documented interface `run_all/1` over the three stub
     benches (`stub-noop`/`stub-count`/`stub-arith`, plain-binary names —
     `run_benchmark/3 -> to_bin/1` has no clause for tuples).
2. **`/Users/sac/smalt/justfile.d/46-bench.just`** — `just court-bench`
   (shebang recipe, prefixed `BENCH8_*` vars, OTP-29 PATH, honors
   `COURT_BENCH_DIR`); one import line added to the root justfile.
3. **CI fence wiring note (BENCH-8 → BENCH-1 typed note)**: the
   "heap Δ ≤ 32 words caller-local" fence is NOT enforceable via
   `erlang:memory(total)` — that counter is node-global (all processes plus
   system allocators), so a delta over it is neither caller-local nor stable
   under concurrent lanes. The lawful caller-local primitive is an isolated
   per-bench worker's `process_info(Pid, total_heap_size)` delta (words,
   caller-local by construction). Documented as the follow-up for the fence
   owner (BENCH-1); this escript is the runner only, it does not fence.

## Verification (real output)

`just court-bench` (final run, exit 0):

```
[court-bench] root=/Users/sac/smalt benches=/Users/sac/smalt/bench
[court-bench] compiled 7 module(s): bench_amqp_frame, bench_concurrency_ceiling, bench_cosmos_cas, bench_json_streaming, bench_powl_pipeline, court_receipt, smalt_bench_court
[court-bench] run_all/0 absent — fallback: run_all/1 stub set
[court-bench] COURT PASS rows=3 receipt=tmp/bench/court_bench_20261021T225058.824Z.jsonl
EXIT: 0
```

Receipt rows (`tmp/bench/court_bench_20261021T225058.824Z.jsonl`):

```
{"name":"stub-noop","n":1000,"wall_ms":0.003,"ops_sec":303766707.169,"ns_per_op":3.292,"reds_per_op":0,"heap_delta":0}
{"name":"stub-count","n":500,"wall_ms":0.334,"ops_sec":1497005.988,"ns_per_op":668,"reds_per_op":40.008,"heap_delta":18824}
{"name":"stub-arith","n":200,"wall_ms":0.025,"ops_sec":7946914.61,"ns_per_op":125.835,"reds_per_op":20,"heap_delta":0}
```

Negative contract (fail-closed): a bench dir with a syntax-broken `.erl`
exits **1** with typed `{erlc_failed, 1, Out}` (tested against
`/tmp/bench8_broken`; output showed real erlc diagnostics, EXIT: 1).
Zero-errors caveat: the stub path itself had 0 errors; concurrent lanes'
modules carry OTP-29 deprecation warnings (e.g. `catch` in
`bench_cosmos_cas.erl`) which the runner surfaces but does not fail on —
they are their lanes' to fix.

## Interface timing (bounded poll, honest)

Bounded-polled `bench/smalt_bench_court.erl` every 20 s for the full
15-minute window for a compiling module exporting `run_all/0`: the module
went green early in the window (BENCH-2 landed fixes mid-lane) but
`run_all/0` never appeared — poll timed out (exit 3). Per the task spec, the
wiring is built against the documented interface (`run_all/1` fallback) and
the `run_all/0` dispatch is in place: when BENCH-2 lands it, `bin/court-bench`
picks it up with no changes.

## Compile-freeze SLA disclosure (cross-lane unblock fixes)

Both fixes are one-line renames of uppercase-illegal function names in other
lanes' in-flight files; both were re-verified to compile after the fix:

- `bench/bench_amqp_frame.erl` — `F0(...)` → `f0(...)` (4 sites; `F0` parses
  as a variable in Erlang, illegal as a function name). Owner lane should
  re-read on next touch.
- `bench/court_receipt.erl` — `Comma(...)` → `comma(...)`. Self-healed
  observation: on my retry the file already compiled (owner lane landed its
  own fix concurrently); my python patch was a no-op assertion-verified
  against the already-fixed state — net diff from me: none on this file.

## Machine

`just bench-machine`: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
(bench-machine reports the Mix OTP-28 chain; the court runner itself executes
on the local erlmcp OTP 29.0.5 toolchain at `/opt/homebrew/opt/erlang@29`.)

## Artifacts

- `/Users/sac/smalt/bin/court-bench` (executable, escript)
- `/Users/sac/smalt/justfile.d/46-bench.just`
- `/Users/sac/smalt/justfile` (one import line appended)
- Build root `_bench-escript/` (lane lease — reclaim at integration)
- Receipts: `tmp/bench/court_bench_*.jsonl` (scratch tier)
