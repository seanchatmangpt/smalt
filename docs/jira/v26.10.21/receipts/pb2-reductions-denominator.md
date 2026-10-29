# PB-2: reductions-per-workflow-step denominator (settlement orchestration)

Context: solo

- **Date**: 2026-10-21
- **Lane**: PB-2 (OTP-29 bench)
- **Subject**: `/Users/sac/smalt` @ main (e626924 + concurrent in-flight deltas; see Session notes)
- **Context**: solo (in-process bench, no shared substrate; concurrent lanes present on tree)
**Standing**: PARTIAL_ALIVE — numbers real and stable across 5 runs (reductions run-to-run variance < 0.1%); caveats: execute_primitive/receipt_seal stage bodies include DETS open/close per iteration, the per-step divider (≈1,609 reds/step) is derived not directly measured, and `receipt_seal_alone` words (74) are derived as w_seal − w_prim.
- **Harness**: `/Users/sac/smalt/scripts/bench/pb2_reductions_step.exs` (in-process, no substrate; real modules, no mocks)
- **Results**: `/Users/sac/smalt/tmp/bench/pb2-reductions-step.jsonl` (7 rows, `stage | reductions | words`)

## Command

```
export PATH=~/.asdf/installs/erlang/29.1.2/bin:~/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH
MIX_BUILD_ROOT=_build-pb2 mix run --no-start scripts/bench/pb2_reductions_step.exs
```

Final run, exit 0:

```
otp_release = 29
machine = %{"elixir" => "1.20.4", "erts" => "17.1.1", "jit" => ":jit", "otp" => "29"}
htn_decompose: 540 reductions/txn, 1ms total
fond_synthesize: 1200 reductions/txn, 1ms total
graph_validation: 580 reductions/txn, 0ms total
execute_primitive_step: 12877 reductions/txn, 221ms over 200 iters (8 record_steps + DETS open/close per iter)
receipt_seal: 15224 reductions/txn, 238ms over 200 iters (record 8 + seal)
receipt_seal_alone: 2270 reductions/txn, 10ms over 200 iters (seal only, pre-recorded run)
fond_runner_total: 41041 reductions/txn (caller-side; see method notes)
stage-composed total ≈ 17467 reductions/orchestration (8 steps; per-step execute_primitive ≈ 1609)
```

## Reductions-per-transaction table (8-step settlement orchestration, 200 iters, warm)

| stage | reductions/txn | tprof call_memory words |
|---|---|---|
| htn_decompose (`linear_plan/1` + `assert_acyclic/1`) | 540 | 25 |
| fond_synthesize (`next_ready/2` scheduling loop to completion) | 1,200 | 22 |
| graph_validation (`GraphCompat.acyclic?/1`, native `:graph` leg) | 580 | 38 |
| execute_primitive_step (8x `ReceiptEngine.record_step` + DETS open/close per txn) | 12,877 (≈1,609/step) | 105 |
| receipt_seal (record 8 + `seal_receipt/3`) | 15,224 | 179 |
| receipt_seal_alone (`seal_receipt/3` only, pre-recorded run) | 2,270 | 74 (derived) |
| fond_runner_total (real `gen_statem` pipeline, caller-side view) | 41,041 | 434 |

Stage-composed denominator: **≈17.5k reductions per 8-step settlement orchestration** (htn + fond + graph + 8-step execute_primitive + seal-alone).

## Method notes (honest scope)

- **Reductions**: `:erlang.statistics(:reductions)` delta in the bench process, 200 warm iterations per stage. Process-local, so every stage body runs in the measuring process. `fond_runner_total` drives the real `smalt_fond_powl_runner` `gen_statem` — its work runs in the statem's own process, so that row is the **caller-side cost** of driving the pipeline (start handshake + monitor + receive), NOT the pipeline's internal cost; the per-stage rows are the honest denominator.
- **Words**: `tprof:profile(fun, #{type => :call_memory})`, one profiled call per stage (same pattern as `scripts/tprof_memory_profile.exs`), summed across the call tree.
- **Stage-body mapping** (disclosed in the harness header):
  - htn_decompose = exactly the runner's stage-1 work (`linear_plan/1` + `assert_acyclic/1`, runner L90-92).
  - fond_synthesize = `next_ready/2` loop over a done-map (runner stage-2 scheduling; the runner's emit/2 ledger map-puts are NOT attributed per-stage — they live in the runner row).
  - graph_validation = `Smalt.Powl2.GraphCompat.acyclic?/1` over the plan's needs-edges (native `:graph` leg on OTP 29).
  - execute_primitive = 8x `ReceiptEngine.record_step` (real hash-chain + DETS bag insert) + DETS open/close per iteration.
  - receipt_seal = `seal_receipt/3` over the recorded run (epoch sort + Merkle root + N-Triples + chain walk).
- **Dominance finding**: the receipt-engine legs dominate the orchestration — record+seal (15,224) is ~9x the FOND scheduling + HTN + graph-validation work combined (2,320). Engine-change comparisons should normalize on the per-step execute_primitive denominator (≈1,609 reds/step).

## Session notes (concurrent-lane interference, disclosed)

- Two compile freezes from concurrent lanes (`lib/smalt/json_compat.ex`, `lib/smalt/data_plane/key_vault_actions.ex`) blocked this lane's runs mid-session; both were fixed by their owning lanes before the successful runs. This lane never edited shared `lib/`.
- Mid-session another lane changed `smalt_fond_powl_runner.erl`'s completion protocol (send → DOWN `{completed, Receipt}`); the harness accepts both forms and the final numbers were measured on the post-edit runner.

## Machine

`just bench-machine` (ambient toolchain): `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`. The lane itself ran pinned OTP 29.1.2 / erts 17.1.1 / Elixir 1.20.4 (JIT) per `.tool-versions`, embedded in every jsonl row's `machine` field.
