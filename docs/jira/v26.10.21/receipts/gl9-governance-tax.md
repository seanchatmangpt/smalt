# GL-9: GraphLaw Governance-Tax Differential

**Standing:** **ALIVE** (differential measured, receipt-identity proven, refusal witness live)
Context: solo · Date: 2026-10-21 · Repo: /Users/sac/smalt
Charter: `docs/jira/v26.10.21/DIRECTIVES.md` (GL charter exercise)

## Subject

The 4-step settlement workflow (`ex:SettlementShape` law: maxInclusive
ceiling on `amount`, minCount 1 on `approver`, `powl:notEquals`
self-approval exclusion) executed through `Smalt.POWL2.Executor` two ways:

- **unguarded**: plain `Transition` ops (op = fun/1), no law seam.
- **graphlaw_guarded**: GL-1 seam — `op = {:graphlaw_guard, shape_id, guard, inner_op}`,
  guard compiled by GL-2 (`Smalt.POWL2.LawCompiler.compile_shape/2`) from
  SHACL Turtle law text.

Topology is a ChoiceGraph 4-chain, which the executor walks fully
sequentially in the caller process (no Task waves), so caller
`:reductions` deltas and wall clock capture the entire execution: exact
differential accounting, no scheduler spill.

## Result

n=500 interleaved pairs per run after 100 warmup pairs, two runs:

| run | unguarded reds/step | guarded reds/step | reds tax/step | µs tax/step (median-diff) | receipt identity | refusal witness |
|---|---|---|---|---|---|---|
| 1 | 234.2 | 281.4 | **+47.24** | **+0.25 µs** | true | SettlementShape/maxInclusive/amount |
| 2 | 234.2 | 281.7 | **+47.49** | **+0.25 µs** | true | SettlementShape/maxInclusive/amount |

Refusal witness proves the seam is live (non-vacuity): over-ceiling
amount (10,001) refuses with typed andon, op never runs.

## Wall-clock detail (run 1, run 2 differed only in tail)

| arm | reds/step | p50 µs | p99 µs |
|---|---|---|---|
| unguarded | 234.2 | 5.00 | 18.00 |
| graphlaw_guarded | 281.4 | 6.00 | 1147.00 |

The guarded p99 is a scheduler/GC tail artifact of the small absolute
scale (~6 µs/run): the tax number that survives across runs is the
median-diff **0.25 µs/step**; means and tails at this scale are
machine-noise. Reductions are exact integers, not timers — the
**+47.2–47.5 reds/step (~20% reduction overhead)** is the honest,
run-stable governance tax.

## Receipt identity (conforming runs)

Same run id through both arms → projected receipts (at_ms stripped)
byte-equal: **true**. Guarded settlement does not change the conforming
receipt, only its cost.

## Commands

```
export PATH=~/.asdf/installs/erlang/29.1.2/bin:~/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH
MIX_BUILD_ROOT=_build-gl9 mix run --no-start scripts/bench/gl9_governance_tax.exs
```

Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"otp":"29.1.2","elixir":"1.20.4-otp-29"}` (pinned toolchain per `.tool-versions`, not the ambient 1.19.5/OTP 28 reported by `just bench-machine`).

## Results file

`tmp/bench/gl9-governance-tax.jsonl` (3 rows: unguarded, graphlaw_guarded,
governance-tax; schema lane/surface/op/n/ops_per_sec/p50_ms/p95_ms/p99_ms/
errors/machine/reductions_per_step + tax/identity/witness fields).

## Falsifiers

- Guard is a no-op passthrough (tax 0 reds) — REFUTED: +47.2 reds/step measured.
- Guarding changes conforming receipts — REFUTED: projected receipts equal.
- Seam is vacuous (guard never refuses) — REFUTED: refusal witness fired.

## Disclosed compile-freeze unblocks (SLA, in other lanes' in-flight files)

1. `lib/smalt/powl2/andon_wire.ex` (GL-8 lane, untracked): deleted two
   corruption marker lines (`inal-marker`, `garbage-marker`) that broke
   every lane's compile. Also restored/ The file later compiled clean.
2. `lib/smalt/powl2/law_compiler.ex` (GL-2 lane): `parse_statement/1`
   handed the raw subject token tuple to `local_name/1` (binaries only) —
   added a `local_name(token)` clause unwrapping via the module's own
   `term_value/1`. Later runs show `SettlementShape/...` rule ids (the
   owner lane has since improved local-name handling); my fix clause
   remains compatible.

## Standing notes

- Concurrent lanes broke shared compile repeatedly during the window
  (andon.ex duplicate defp, wasm/worker.ex, cosmos_query_metrics.ex
  `is_integer/3` guard misuse, tls.ex); all were owner-lane-repaired, not
  by this lane. Green-compile polling loop was used, not eviction.
- Harness: `scripts/bench/gl9_governance_tax.exs` (this lane's own file,
  not shared bench infra). In-process, no substrate, real DETS, real
  executor, real compiled law — Chicago discipline.

## Integrity re-check (CTXFILL-2, 2026-10-21)

```
$ ls -l tmp/bench/gl9-governance-tax.jsonl
-rw-r--r--@ 1 sac  staff  783 Oct 21 15:25 tmp/bench/gl9-governance-tax.jsonl
exit 0
$ wc -l tmp/bench/gl9-governance-tax.jsonl
       3 tmp/bench/gl9-governance-tax.jsonl
$ python3 -c "import json;[print(r['lane'],r['op'],r['n'],r.get('reductions_per_step')) for r in map(json.loads,open('tmp/bench/gl9-governance-tax.jsonl'))]"
gl9 unguarded 500 234.19
gl9 graphlaw_guarded 500 281.42
gl9 governance-tax 500 None
exit 0
```

Rows on disk match the receipt's table (234.19/281.42 reds/step, n=500,
two arms + tax row). Standing unchanged: ALIVE.

## Addendum (TTV-7 warmed re-run, 2026-10-21)

TTV-7 re-ran the guarded arm with a 10_000-execution burn-in and a
100_000-sample measured phase (`tmp/bench/ttv7_gl9_warmed.exs`, copy-and-extend;
this harness was NOT edited). Result (`tmp/bench/ttv7-warmed-p99.jsonl`,
receipt `docs/jira/v26.10.21/receipts/ttv7-warmed-p99-standard.md`):

| profile | n | p50 µs | p95 µs | p99 µs | max µs | reds/step |
|---|---|---|---|---|---|---|
| COLD | 1_000 | 7 | 42 | 137,853 | 584,120 | 285.5 |
| WARM | 100_000 | 6 | 42 | 197,128 | 3,057,891 | 285.4 |

- Reductions confirm the original governance tax is compute-stable:
  warmed 285.4 reds/step vs the original 281.4–281.7 (drift < 1.5%);
  first-half vs second-half warmed drift 0.073%.
- Wall-clock: median and p95 identical cold vs warm (6–7µs / 42µs). The
  p99 tail did NOT collapse with warming — the pre-registered falsifier
  ("a warmed re-run reproducing the ms-tail would re-open the threat")
  **FIRED**: warm p99 197,128µs (max 3.06s) under machine load average
  132 on 16 cores (concurrent lanes). This is a load-class tail
  (scheduler descheduling under oversubscription), not cold-start noise
  and not a governance regression — the guarded p99 quoted in the
  original table (1147µs) must not be read as an operational tail in
  either direction.
- Correction to the original wall-clock interpretation: the original
  "scheduler/GC tail artifact" framing was itself a cold+load mixture;
  the warmed dual-profile split shows the tail is dominated by machine
  load, not warm-up. Original reduction and tax numbers stand unchanged.

## Falsifier (standing)

A warmed re-run under a QUIESCED machine (load < ~2× cores) reproducing
a ms-class p99 would re-open the tail as a real per-step regression.
Under the load-132 run above, tail status is UNRESOLVED-under-load, not
closed.
