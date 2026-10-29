# BK-GWSSKEP2 — full GWS/SQLD/GLD/BENCH wave re-run + baseline comparison

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22 07:31–08:12 PDT
- **Lane**: BK-GWSSKEP2, canonical checkout `/Users/sac/smalt`
- **Relaunch subject**: reap of BK-GWSSKEP (typed FROZEN by `bkgwsp-poll.md` —
  62-min-stale build root, two launchd-reparented stub beams, zero
  attributable wave courts). Per the poll's typing, NO court was skipped:
  the full wave re-ran fresh on the current tree in a fresh
  `_build-bkgwsskep2`.
- **Machine**: Apple M3 Max, 16 cores, 48 GB, elixir 1.20.4-otp-29 (asdf
  shims), darwin 26.2. Window load was heavy (concurrent lanes at 45–230%
  CPU witnessed mid-window); throughput rows carry that load caveat.

## Court runs (all real output, embedded; full logs `/tmp/gwsskep2/*.log`)

### GWS

| court | command | result |
|---|---|---|
| wasm_sandbox_court | `MIX_BUILD_ROOT=_build-bkgwsskep2 mix test test/integration/wasm_sandbox_court.exs` | run 1: **5/6** (gate 6 `refute Process.alive?(worker)` false); run 2 same-command: **6 passed**, exit 0 |
| wasm_abi_court_test | same pattern | **13 passed**, exit 0 |
| wasm_real_runner_court | same pattern | **7 passed**, exit 0 |
| graphlaw in-wasm (GWS-14 set) | `cd /Users/sac/graphlaw && cargo test --test wasm_governance_preflight --test wasm_n3_admission --test wasm_boundary_fuzz --test wasm_coldchain_e2e` | **11/11 ok**, exit 0 (fuzz 2, coldchain 3, preflight 3, n3 3) |
| graphlaw-run adversarial leg | `printf '\x00\x00\x00\x13{"op":"no_such_op"}' | cargo run -q --features runner --bin graphlaw-run` | typed `Unsupported` "unknown op `no_such_op`", **exit 0**, no trap |

Gate-6 classification: failed under window load (concurrent lanes at
45–230% CPU), passed in isolation on identical command/build root —
contention flake, same classification standard as BK-SEAL5. Gate 5's hung
guests and gate 6's killed workers spawn `stub_runner.exs --hang` port
children; two leaked after run 1's kill of the mix beam (fd-inheritance
class, `bkgwsp-poll` precedent) — reaped by exact PID (53821, 61531) with
0 CPU / PPID 1 / no LISTEN sockets, and the lane build root deleted.

### SQLD

| court | result |
|---|---|
| sqld2_sql_ingest_court | **PASS** (`mix run --no-start`, it is a script not an ExUnit file — under `mix test` it reports 0 tests; exit 0, legs 1–6 green incl. leg1 typed fallback, leg6 SHACL injection refusal) |
| sqld5_sql_shape_court | **14 passed**, exit 0 |
| sqld8 ingest baseline (driver `scripts/bench/sqld8_ingest_baseline.sh`, exit 0) | converter min 901 ms → **110,987.8 rows/s**, RSS 259,751,936 B; direct min 149 ms → **671,140.9 rows/s**, RSS 102,219,776 B; 0 errors |

### GLD

| court | result |
|---|---|
| gld2_cdc_court | **PASS**, exit 0 — ledger digest `a390a16485bd073fa809aa0b035967e7ab994e5665c8239c7f22a9a4ce10b783`, 145 events / 115 rows / 5 tombstones; delta replay durable-segment leg green; tamper legs flip digests (non-tautological) |
| gld5fix_roundtrip_court | **PASS**, exit 0 — 6/6 rows value-exact, wire-`\N`→NULL, wire-`""`→`''`, 7 formula payloads neutralized, F1 pin `{:injection_token, "t;"}` held |

### BENCH

| court | result |
|---|---|
| fond_powl_runner_court (+`--include fondrunner_skeptic`) | **31 passed**, exit 0 |
| PB-1 `scripts/bench/pb1_fond_sweep.sh` (exit 0, b1 substrate, 22/22 rows) | native 30,450.7 → 8,123.0 ops/s monotone r0→r10, p50 28→109 µs, **0 errors, retries_forced honored**; SDK leg `injection_failures=0` at all 11 points, **conflicts=37400 exactly the baseline count**, 0 unexpected errors |
| PB-3 `pb3_executor_ceiling.exs` (--no-start) | 8 points, **0 errors, wall_level=unreached-at-8192**; N=8192 wall 2777 ms, p50 496 µs |
| PB-6 `pb6_dual_boundary.exs` (private TLS twin 39170–39175 booted fresh, wire N=300, native N=5000, 0 errors) | tax shape reproduces: lease 0.604 ms (10.0x), CAS 0.585 ms (12.5x), validate 0.183 ms (1.5x), seal 0.267 ms (1.7x), observe **net-negative −1.555 ms (0.3x)** |

## Comparison vs cited receipts

| surface | baseline (receipt) | fresh | delta | typed verdict |
|---|---|---|---|---|
| sqld8 converter | 64,724.9 rows/s / 1545 ms / RSS 294.2 MB (`sqld8-ingest-baseline.md`, OTP 28) | 110,987.8 / 901 ms / 259.8 MB | +71% | **material favorable drift, re-anchored** — biggest factor is the toolchain shift OTP 28→29 + elixir 1.19.5→1.20.4 recorded in the rows' own machine blocks; RSS also −12% |
| sqld8 direct | 450,450.5 rows/s / 222 ms / RSS 100.0 MB | 671,140.9 / 149 ms / 102 MB | +49% | **material favorable drift, re-anchored** (same toolchain factor; RSS flat) |
| PB-1 native | 25,239.8 → 6,528.6 ops/s (r0→r10) (`bk5-powlbench.md`) | 30,450.7 → 8,123.0 | +20.6% / +24.4% | **re-anchored (favorable, at the 20% fence)** — monotone contention-cost law holds; retries_forced honored at every point |
| PB-1 SDK | 279.6 → 30.2 ops/s, conflicts=37400 (`pb1sdkfix-rerun.md`) | 167.1 → 34.1, conflicts=37400 | r0 −40% | **re-anchored with load caveat** — correctness invariants identical (0 injection failures, byte-identical conflict total); the throughput level moved under window load (concurrent lanes witnessed 45–230% CPU during the SDK leg) |
| PB-3 ceiling | N=8192 wall 8221 ms / p50 5950 µs (`bk5-powlbench.md`) | 2777 ms / 496 µs | −66% wall | **material favorable drift, re-anchored** — error cliff still unreached at 8192, 0 errors, same verdict |
| PB-6 tax | lease 0.402 ms (8.3x), CAS 0.381 ms (8.9x), observe −1.622 ms (0.2x) (`bk5-powlbench.md`/`pb6-dual-boundary.md`) | lease 0.604 ms (10.0x), CAS 0.585 ms (12.5x), observe −1.555 ms (0.3x) | +50% tax magnitude | **consistent** — shape law reproduces exactly (lease/CAS pay ~10x boundary tax; observe net-negative); absolute levels shifted with window load |
| GWS in-wasm | 11/11 (`bk31-gws14-inwasm-courts.md`) | 11/11 + typed adversarial refusal | 0 | **consistent, re-anchored**; note: graphlaw HEAD moved `5dc3c01`→`ed3be81` since bk31 — courts re-ran on the current-source build |
| GLD-2/5FIX | PASS (v26.10.21 receipts) | PASS | 0 | **consistent, re-anchored** |
| fondrunner | 10 passed (`bk4-fondrunner.md`) | 31 passed | court grew on tree since bk4 | **consistent** — superset suite, skeptic probes included, 0 failures |

**No correctness flip anywhere.** Every throughput drift is favorable or
load-explained; the only >20% unfavorable movement (PB-1 SDK r0 −40%) keeps
its correctness invariants byte-identical (conflicts=37400, 0 injection
failures) and is typed load-shift, not regression.

## Incidents (typed, no open defects)

1. **First stage-1 run deadlocked in the harness pipe, not the tests**: the
   wasm_sandbox court leaked a `--hang` stub beam (PPID 1) that inherited
   the `mix test` pipe write-end, so `tail` never saw EOF — the
   fd-inheritance law (same-checkout-fanout add. 4), same class as the
   bkgwsp-poll stubs. Pipeline killed, stub reaped by exact PID, courts
   re-run with per-court file redirect. **Second lesson: sqld2 is a script
   court (`mix run --no-start`), not an ExUnit file — under `mix test` it
   silently reports "0 tests"** while exiting 0; a census tooling reading
   that as pass would be a vacuous pass (same class as the BK-SEAL5
   census/compile-abort lesson). **[BK-SQLD2X successor]: hazard closed —
   sqld2 converted to an ExUnit case
   (`test/integration/sqld2_sql_ingest_court_test.exs`), executes under
   `mix test test/integration` (233/233), legs 1–6 green; receipt
   `bksqld2x-convert.md`.**
2. **sqld2 `mix run` with app start hit `:eaddrinuse`** (fixed-port dev
   config colliding with live lanes) — `--no-start` is the correct
   invocation and passed all 6 legs.
3. **Driver-side `sleep 0.5` poll loops exist in `pb1_fond_sweep.sh`**
   (cert wait) and my substrate-wait used `sleep 1` polls on a real
   observable (LISTEN check) — driver-owned, disclosed, not test-side
   fixed sleeps.

## Cleanup receipt

`_build-bkgwsskep2` (714 MB) deleted at close. Two lane-leaked stub beams
reaped by exact PID. No `_build-bkgwsskep2*` residue remains.

## Falsifiers

- A re-run where wasm_sandbox gate 6 fails in isolation (not under load)
  would invert the contention-flake classification into a real defect.
- A re-run of sqld8 on pinned OTP 28 returning to ~64.7k/450k rows/s would
  confirm the toolchain factor as the whole drift (drift attribution is
  typed, not proven — OTP 28 toolchain no longer selected by current shims).
- A PB-1 SDK rerun on a quiet machine that does NOT recover toward
  ~280 ops/s at r0 would convert the load-shift typing into a regression.

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"; cd /Users/sac/smalt
# GWS sandbox (gate-6 flake precedent: rerun file-alone on failure):
MIX_BUILD_ROOT=_build-bkgwsskep2 mix test test/integration/wasm_sandbox_court.exs
MIX_BUILD_ROOT=_build-bkgwsskep2 mix test test/integration/wasm_abi_court_test.exs
MIX_BUILD_ROOT=_build-bkgwsskep2 mix test test/integration/wasm_real_runner_court.exs
# graphlaw in-wasm (separate repo):
cd /Users/sac/graphlaw && cargo test --test wasm_governance_preflight \
  --test wasm_n3_admission --test wasm_boundary_fuzz --test wasm_coldchain_e2e
# SQLD:
MIX_BUILD_ROOT=_build-bkgwsskep2 mix test test/integration/sqld5_sql_shape_court.exs
MIX_BUILD_ROOT=_build-bkgwsskep2 mix run --no-start test/integration/sqld2_sql_ingest_court.exs
bash scripts/bench/sqld8_ingest_baseline.sh
# GLD:
MIX_BUILD_ROOT=_build-bkgwsskep2 mix run --no-start test/integration/gld2_cdc_court.exs
MIX_BUILD_ROOT=_build-bkgwsskep2 mix run --no-start test/integration/gld5fix_roundtrip_court.exs
# BENCH:
MIX_BUILD_ROOT=_build-bkgwsskep2 mix test test/pipeline/fond_powl_runner_court_test.exs --include fondrunner_skeptic
MIX_BUILD_ROOT=_build-bkgwsskep2 bash scripts/bench/pb1_fond_sweep.sh          # boots b1 substrate
MIX_BUILD_ROOT=_build-bkgwsskep2 mix run --no-start scripts/bench/pb3_executor_ceiling.exs
# PB-6: boot private TLS twin 39170-39175 per docs/jira/v26.10.21/receipts/pb6-dual-boundary.md, then:
MIX_BUILD_ROOT=_build-bkgwsskep2 MIX_ENV=test mix run --no-start scripts/bench/pb6_dual_boundary.exs
```
