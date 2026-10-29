# BENCH-ERLANG

Pure-Erlang benchmark ARD/PRD for the v26.10.21 OTP-29 window. This document is
the contract the implementation lanes build against: bulk wall-clock, reduction
accounting, heap fencing, zero framework overhead, pure-Erlang arbitration
court, escript runner, CI fences. Every current-state claim below is audited
against the tree as of 2026-10-21 with the raw grep/census output embedded.

## Goals

1. **Zero framework overhead in the measured path.** No benchmark framework
   (Benchee or any other) loads inside a measured section. Timing is
   `:erlang.monotonic_time` aggregates; cost accounting is per-process
   `process_info(worker, :reductions)` deltas; heap claims ride isolated
   workers with `process_info(pid, :heap_size)` after double-GC, never node
   globals (`erlang:memory`/`statistics(:reductions)` banned in fences).
2. **Bulk wall-clock + reduction accounting.** Every benchmark emits, per row:
   wall ms (aggregate of paired rounds, min-of-N), reductions delta, and (for
   heap rows) caller heap delta in words.
3. **Heap fencing.** Any "cheap on the caller" claim carries an AR-BENCH-02
   caller-heap-delta fence.
4. **Pure-Erlang arbitration court.** A benchmark result is admitted only if a
   court can distinguish it from a seeded perturbation (non-vacuity). A court
   that cannot exit 1 is the failure.
5. **escript runner, no Mix in the hot path.** The runner is a plain escript:
   no Mix/compile step between rounds, no dep tree in the measured process.
6. **CI fences are ratio-based.** Fences compare against a sleep-free,
   independent baseline (paired rounds, min-of-N) — no absolute-ms fences
   (`docs/NO_SLEEP_DOCTRINE.md` ratio-fence law).

## Requirements

### AR-BENCH-01 — wall-clock + reduction accounting

- Wall-clock: aggregate `:erlang.monotonic_time/1` deltas, paired rounds,
  min-of-N. No per-iteration timing, no fixed sleeps anywhere in the loop.
- Reductions: **per-process** `:erlang.process_info(WorkerPid, :reductions)`
  deltas around the measured body executed in an **isolated worker process**
  (per-process reduction accounting since OTP 18; probe-verified — see
  BENCH-10 evidence below). `:erlang.statistics(:reductions)` is **node-global**
  and BANNED in fences: BENCH-10's skeptic probe measured it inflated 2.17x
  under concurrent load, so its delta attributes other schedulers' work to the
  measured body. (Evidence:
  `docs/jira/v26.10.21/receipts/bench10-skeptic.md`.)
- Historical note: the PB-2 / IMPL-17 / GL-9 pattern on disk
  (`scripts/bench/pb2_reductions_step.exs`,
  `scripts/bench/impl17_amqp_reductions.exs`,
  `scripts/bench/gl9_governance_tax.exs`) uses the node-global
  `statistics(:reductions)` delta; those scripts are compliant with the
  pre-BENCH-10 wording and remain valid as scenario harnesses, but any NEW
  fence-class claim must use the per-process primitive above.
- Both counters are read as deltas around the measured section executed in
  the isolated worker, so the delta is attributable to the body alone. Any
  body that must run in another process reports its reductions as caller-side
  cost of the call only
  (witnessed in `pb2_reductions_step.exs` header: the
  `fond_runner_total` row measures wall-cost of `run/1`, its reductions are
  NOT attributed to the pipeline — the per-stage rows are the honest
  denominator).

### AR-BENCH-02 — caller heap fence (Δ ≤ 32 words)

- Any claim of the form "the caller's heap does not grow" is fenced: caller
  heap delta must be ≤ 32 words across the measured section.
- **Valid measurement requires caller-local accounting.** The fence is against
  the caller's own heap, read via
  `:erlang.process_info(WorkerPid, :heap_size)` (live words) taken after a
  **double `:erlang.garbage_collect()`** in an **isolated worker process**
  (`garbage_collect(); garbage_collect()` — the second pass reclaims
  references the first promoted), pre/post around the measured body. Use
  `:heap_size` (live words after GC) for the ≤32-word fence; `:total_heap_size`
  includes the high-water mark and overstates a compliant caller.
- **BENCH-10 evidence (folded)**: the draft reference code's
  `:erlang.memory(:total)` moved **1792 MB** in a probe while an unrelated
  process allocated it and the measured caller allocated **0** — a
  node-global allocator total cannot fence a caller-local claim (full probe:
  `docs/jira/v26.10.21/receipts/bench10-skeptic.md`).
  `:erlang.memory/0,1` and `:erlang.statistics(:reductions)` are **banned
  inside AR-BENCH-01/02 fences**. Valid primitives: `process_info(WorkerPid,
  :heap_size)` after double-GC (this section), `process_info(WorkerPid,
  :reductions)` deltas (AR-BENCH-01), or the tprof `:call_memory` pattern
  (`scripts/tprof_memory_profile.exs`, as used by PB-2) for
  allocated-words-per-call.

### AR-BENCH-03 — zero framework overhead

- No Benchee (or any bench framework) in the measured path. See audit table
  T1: Benchee currently exists at exactly two locations; both are deletion
  targets for the implementation lane.

### AR-BENCH-04 — pure-Erlang arbitration court

- Runner emits rows; the court re-runs a seeded perturbation (e.g. a
  reduction-inflating no-op injected into the measured body) and must
  distinguish baseline from perturbed output (exit 1 on failure to
  distinguish). Baseline → BEFORE → SHIM (`SHIM-COURT` marker) → AFTER →
  RESTORE byte-exact, per `scripts/shim_court/` protocol.
- Non-vacuity: a court that cannot exit 1 is `VACUOUS GATE` (fail).

### AR-BENCH-05 — escript runner

- `scripts/bench/erlang_bench.escript` (implementation lane delivers): plain
  escript, main/1, reads a lane name from argv, emits one JSON line per row
  (jsonl, hyphenated filenames per `scripts/bench/lib.sh` convention).
  No Mix, no compile between rounds.

### AR-BENCH-06 — CI fences

- Fences are ratio-based: measured/baseline ≤ fence ratio, independent
  baseline, paired rounds, min-of-N. A fence that depends on wall-clock
  absolute bounds is refused at review.

## Current-state audit (2026-10-21)

### T1 — Benchee deletion targets (expected "zero Benchee"; actual: typed)

Command (real output):

```bash
$ grep -rn "benchee" mix.exs lib test
mix.exs:144:      # Benchmarking (ERRC lane 2 Raise): benchee drives scripts/bench/benchee_runner.exs
mix.exs:147:      {:benchee, "~> 1.3", only: [:dev, :test], runtime: false},
```

- `lib/` and `test/`: zero matches — no Benchee usage in shipped or test code.
- Deletion targets that actually exist (implementation lane):
  1. `mix.exs:147` — `{:benchee, "~> 1.3", only: [:dev, :test], runtime: false}`
     plus the explanatory comment block at `mix.exs:144-146`.
  2. `scripts/bench/benchee_runner.exs` — 13,451 bytes, the runner it drives
     (b7b/b8b/b9b rows per the mix.exs comment).
- That is the complete set. Note this contradicts the dispatch expectation of
  "zero Benchee": the honest audit types two deletion targets, not zero.
- **BENCH-9 fold-in**: benchee is cited evidence for the `errc2-benchee`
  receipt — its deletion is a no-op for the zero-overhead requirement, which
  is enforced prospectively (AR-BENCH-03 bans frameworks in the measured path
  of anything landing after this spec). The dep + runner may be retired as
  cleanup, not as a gate; the errc2-benchee evidence pointer must be updated
  in the same diff if retired.

### T2 — census of `scripts/bench/*.exs` classified against AR-BENCH-01/02

Command pattern: per file, counts of `monotonic_time` /
`statistics(:reductions)`-family / `Process.sleep` / heap-primitive usage.
Raw counts (monotonic / reductions / sleep), then classification.

| script | mono | red | sleep | heap prim | AR-BENCH-01 class | AR-BENCH-02 class |
|---|---|---|---|---|---|---|
| a1_change_feed.exs | 2 | 0 | 8 | none | COMPLIANT (wall) — sleeps are scenario staging, not timing | n/a |
| a2_cas_contention.exs | 5 | 0 | 0 | none | COMPLIANT | n/a |
| a3_cross_partition_tx.exs | 2 | 0 | 0 | none | COMPLIANT | n/a |
| a4_crypto_throughput.exs | 6 | 0 | 0 | none | COMPLIANT | n/a |
| a7_hns_rename.exs | 2 | 0 | 1 | none | COMPLIANT (sleep is scenario staging) | n/a |
| a8_lro_storm.exs | 1 | 0 | 3 | none | COMPLIANT (staging sleeps) | n/a |
| b42_dataplane_saturation.exs | 8 | 0 | 1 | none | COMPLIANT | n/a |
| b7_store_beam.exs | 11 | 0 | 0 | `garbage_collect` | COMPLIANT | PARTIAL (GC pin, no fence) |
| b8_amqp_beam.exs | 0 | 0 | 1 | `garbage_collect` | COMPLIANT (`:timer.tc` probe, grandfathered) | PARTIAL |
| b9_eh_beam.exs | 4 | 0 | 0 | none | COMPLIANT | n/a |
| benchee_runner.exs | 0 | 0 | 0 | none | N/A — deletion target (T1) | n/a |
| c10_affidavit_seal.exs | 2 | 0 | 0 | none | COMPLIANT (`:timer.tc` probe, grandfathered) | n/a |
| enclave_loop.exs | 8 | 0 | 1 | `garbage_collect` | COMPLIANT | PARTIAL |
| gl9_governance_tax.exs | 4 | 4 | 0 | none | COMPLIANT (full: wall + reductions) | n/a |
| impl17_amqp_reductions.exs | 2 | 7 | 0 | `garbage_collect` | COMPLIANT (full) | PARTIAL (GC, no fence) |
| pb1_fond_sweep.exs | 2 | 0 | 1 | none | COMPLIANT (staging sleep) | n/a |
| pb2_reductions_step.exs | 2 | 12 | 0 | tprof `:call_memory` | COMPLIANT (full) | COMPLIANT (tprof pattern) |
| pb3_executor_ceiling.exs | 4 | 0 | 0 | none | COMPLIANT | n/a |
| pb5_crosslang.exs | 5 | 5 | 0 | none | COMPLIANT (full) | n/a |
| pb6_dual_boundary.exs | 2 | 0 | 1 | none | COMPLIANT (`:timer.tc` probe, grandfathered) | n/a |
| recon_soak.exs | 2 | 0 | 1 | none | COMPLIANT (staging sleep) | n/a |
| t42_json.exs | 2 | 0 | 0 | `total_heap_size` sampling | COMPLIANT | COMPLIANT (isolated-worker pattern) |
| t45_boot_phases.sh | — | — | — | — | non-Erlang (shell), out of scope | — |

Summary (folded with BENCH-9's audit): 22 `.exs` scripts in scope; 18/22
fully AR-BENCH-01 COMPLIANT, 3 grandfathered `:timer.tc` probes
(`b8_amqp_beam.exs`, `c10_affidavit_seal.exs`, `pb6_dual_boundary.exs` —
retrofit under the new runner, not blockers); 1 N/A deletion target
(`benchee_runner.exs`). 5 scripts carry full reduction accounting
(gl9, impl17, pb2, pb5 crosslang; pb2 is the canonical per-stage pattern),
matching the dispatch expectation that most harnesses already use aggregate
monotonic_time + statistics(reductions). AR-BENCH-02: 2 COMPLIANT (the two
patterns this spec canonicalizes: `t42_json.exs` isolated-worker
`total_heap_size` sampling and `pb2_reductions_step.exs` tprof
`:call_memory`), 3 PARTIAL, rest n/a.

### T3 — AR-BENCH-02 measurement-validity gap (typed, with fix)

- **Gap**: the draft reference code for the heap fence used
  `:erlang.memory(:total)`. That call returns the node-global allocator
  total — all processes, all ETS tables, binary heap, allocator carrier slack
  — not the caller's heap. Using it for a "caller heap Δ≤32 words" fence is
  invalid in both directions: concurrent node activity fails compliant code;
  dilution passes non-compliant code.
- **Correct primitive (binding for implementation lanes, BENCH-10-revised)**:
  - Isolated worker + double-GC + `process_info(pid, :heap_size)` pre/post
    (lineage on disk: `t42_json.exs:65-102` samples `total_heap_size`; new
    fences use `:heap_size` after double-GC per AR-BENCH-02), or
  - `tprof :call_memory` allocated-words-per-call (canonical on disk:
    `pb2_reductions_step.exs`, `scripts/tprof_memory_profile.exs`).
  - `:erlang.memory/0,1` is banned inside AR-BENCH-02 fences.
- Implementation lanes must type-check their fence code against this section
  before landing heap claims.

## Non-goals

- Re-running or re-scoring existing bench lanes' historical results.
- Absolute-ms fences anywhere in this family.

## Open items for implementation lanes

1. Deliver `scripts/bench/erlang_bench.escript` per AR-BENCH-05.
2. Optional cleanup: retire the T1 targets (mix.exs dep + comment,
   benchee_runner.exs) with the errc2-benchee evidence-pointer update in the
   same diff. Not a gate.
3. Retrofit `b8_amqp_beam.exs` / `b9_eh_beam.exs` to AR-BENCH-01 or retire
   them with a receipt.
4. Deliver the AR-BENCH-04 arbitration court (shim-court protocol) with
   non-vacuity witness.

## Status (2026-10-21, BENCH-12)

Audited against the tree 2026-10-21; full detail in `bench/README.md`
(per-plane harness table, receipts schema, cross-language denominator table).

| AR | status | evidence |
|---|---|---|
| AR-BENCH-01 wall + reductions | LANDED (core + all 5 plane harnesses) | `bench/smalt_bench_court.erl` (`run_benchmark/3`, court_selftest PASS witness `tmp/bench/court_bench_20261021T223254.701Z.jsonl`, 3 rows); `court_bench_{cosmos,amqp,powl,json,ceiling}.jsonl` |
| AR-BENCH-02 heap fence | LANDED (core heap_delta + BENCH-6 gates) | core double-GC `heap_size` delta; `court_bench_json.jsonl` `heap_gate_le_2mb=true`, peak 38,504 B |
| AR-BENCH-03 zero framework | LANDED | all five harnesses pure `erlc`-compiled, no Benchee; amqp loads the Mix-built FrameCodec beam by code path (documented choice) |
| AR-BENCH-04 arbitration court | PARTIAL — self-court landed with fail-closed validate/parse; seeded-perturbation shim-court not landed | `court_selftest/0` (exit 0/1); Open item 4 |
| AR-BENCH-05 escript runner | PENDING-BENCH-1 — not landed; 20-min bounded poll negative | Open item 1 |
| AR-BENCH-06 CI fences | NOT STARTED | — |

Cross-language denominators (Elixir harness vs pure-Erlang court):
amqp **PARITY** (254.3 vs 254.5 reds/frame, Δ0.08%); cosmos **PARITY**
(p99 0.543–0.672 ms inside the 2x T43 fence of ≤2.08 ms); powl **TYPED
DIVERGENCE** (caller-side 17.5k/8-step PB-2 vs total-work 45,182.7/4-step
BENCH-5 — accounting scope, not a perf contradiction); json **TYPED
DIVERGENCE** (different corpora/modes, no same-corpus differential); GL-9 tax
**MISSING court** (PENDING-BENCH-2). Full table: `bench/README.md`.

## Warmed-P99 standard (TTV-7, 2026-10-21)

Sub-microsecond-scale benches (sub-10µs per-step medians) must not quote
wall-clock P99 from un-warmed or load-noisy runs as an operational tail.
Standard, effective immediately for this family:

1. **Burn-in mandatory.** Any bench claiming sub-10µs per-step medians runs
   an un-timed burn-in (10_000 iterations of the exact measured step) before
   the measured phase — primes ETS, code paths, heaps, scheduler caches.
2. **Dual profiles mandatory.** Output carries BOTH a COLD P99 (first 1_000
   samples from a fresh VM, no burn-in — boot/recovery profile) and a
   STEADY-STATE WARMED P99 (post-burn-in, ≥100_000 samples). One number
   without its profile label is not admissible.
3. **Reductions primary, wall-clock secondary.** `:erlang.process_info/2`
   reductions deltas are exact integers and survive machine noise; they are
   the primary denominator for per-step cost. Wall-clock percentiles are
   secondary and must be reported with the machine-load context
   (load average, concurrent lanes).
4. **Cold-P99 reserved.** The cold profile is admissible ONLY for
   boot/recovery claims (JA-7 class). It must never be quoted as the
   operational tail.

### TTV-7 measured result (falsifier fired — tail NOT closed by warming)

Harness `tmp/bench/ttv7_gl9_warmed.exs` (copy-and-extend of the gl9
harness; `scripts/bench/gl9_governance_tax.exs` NOT edited). Guarded
4-step settlement, pinned toolchain OTP 29.1.2 / Elixir 1.20.4,
`MIX_BUILD_ROOT=_build-ttv7`, under heavy concurrent lane load
(**load average 132 on 16 cores** at run time):

| profile | n | p50 µs | p95 µs | p99 µs | max µs | reds/step |
|---|---|---|---|---|---|---|
| COLD (first 1k, no burn-in) | 1_000 | 7 | 42 | 137,853 | 584,120 | 285.5 |
| WARM (post 10k burn-in) | 100_000 | 6 | 42 | 197,128 | 3,057,891 | 285.4 |

- The operator expectation (warmed P99 collapses toward sub-10µs) is
  **REFUTED on this run**: the warm p99 did not collapse; it reproduced and
  exceeded the cold p99. Per the pre-registered falsifier, a warmed re-run
  reproducing the ms-tail re-opens the tail threat.
- What warming DID show: median (6–7µs) and p95 (42µs) are identical
  cold vs warm, and warmed reductions are stable at 285.4–285.5 reds/step
  (first-half 285.35 vs second-half 285.55, drift 0.073%) — matching gl9's
  281–285 reds/step. The **per-step compute cost of governance is
  unchanged**; the tail is a live, load-class phenomenon (descheduling
  under load-132), not a cold-start artifact and not a governance
  regression.
- Required follow-up: re-run this harness under a quiesced machine
  (load < ~2× cores) before ANY sub-10µs tail claim is quoted. Until that
  receipt exists, the honest quoted number is: median 6µs, reds 285/step,
  tail UNRESOLVED-under-load.

Receipt: `docs/jira/v26.10.21/receipts/ttv7-warmed-p99-standard.md` ·
results `tmp/bench/ttv7-warmed-p99.jsonl`

## See Also

- `docs/NO_SLEEP_DOCTRINE.md` (ratio-fence law)
- `docs/jira/v26.10.21/_LANES.md` (lane partition)
- `scripts/bench/REGISTRY.md` (lane registry)
- `docs/jira/v26.10.21/ARD-PRD.md` (window ARD/PRD)

*Addendum (BK-BMIR3, 2026-10-22): the `tmp/bench/court_bench_20261021T223254.701Z.jsonl` and `tmp/bench/ttv7-warmed-p99.jsonl` evidence cited above now has tracked byte-identical mirrors at `docs/jira/v26.10.21/bench/` (court_bench_20261021T223254.701Z, ttv7-warmed-p99); paired-sha256-verified, provenance `docs/jira/v26.10.21/bench/PROVENANCE.md`.*
