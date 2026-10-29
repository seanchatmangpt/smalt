# BK-4 — FONDRUNNER Receipt

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: BK-4, MIX_BUILD_ROOT=_build-bk4

## Subject

FOND runner = `lib/smalt/pipeline/smalt_fond_powl_runner.erl` (gen_statem
strong-cyclic HTN→FOND→POWL→OCEL loop; siblings `smalt_fond_plan.erl`,
`smalt_fond_seal.erl`). Court already existed at
`test/pipeline/fond_powl_runner_court_test.exs` (283 lines, 10 tests incl.
3 `@tag :fondrunner_skeptic` probes S1–S3 from BK-115); no new court needed.
Task typed it as a real, called surface — this receipt lands the court run.

## Court command

```
MIX_BUILD_ROOT=_build-bk4 mix test test/pipeline/fond_powl_runner_court_test.exs --include fondrunner_skeptic
```

### Embedded real court output

```
Running ExUnit with seed: 129716, max_cases: 32
Including tags: [:fondrunner_skeptic]
Finished in 0.1 seconds (0.00s async, 0.1s sync)

Result: 10 passed
```

exit=0. (The `GenStateMachine terminating ** (exit) {:completed, ...}`
lines in the log are the runner's normal completion exit thrown to the
parent — observed for every clean run, not failures.)

## Strong-cyclic loopback laws, direct witness (`mix run --no-start`)

```
REACHABLE -> {:ok, plan=[:prep, :stage, :commit], step_count=3, event_count=9, merkle=b2c63af4f9284bf4e812713c927fb97850cd184d5f6f94af4f61c630a7c5f608
UNREACHABLE -> fond_loop_bound_exhausted: stuck_on=prep retries=4/3
```

- goal reachable → `{:ok, receipt}` with 32-byte merkle, exact ledger
  composition (3 htn_decompose + 3 step_executed + powl_projected +
  ocel_finalized = 9 events).
- goal unreachable (always-412 contingency, global bound 3) → typed
  `{:fond_loop_bound_exhausted, %{stuck_on: :prep, retries: 4, max_retries: 3}}`
  crash, global bound = R+1 attempts, `stuck_on` names the losing step.

## Court coverage

- (a) happy path: 32-byte merkle, event/step counts, plan identity
- (b) forced 412: exhaustion at bound (11/10), plus bounded-flake loopback
  (2 loopbacks/step then success, 6 fond_412_loopback events) — real Agent
  counter, no mocks, no sleeps (spawn+monitor `run_bounded/2` fences
  liveness probes)
- (c) seal determinism: byte-identical merkle across sequential runs,
  spawned fresh-process sealers, and 8 concurrent full pipelines (S3)
- (d) cyclic plan input → `{:cyclic_plan, remaining}` crash at the assert
- skeptic S2: per-step losing branch names `stuck_on=:stage` with global
  bound; single-step variant retries==3 exactly at bound 2
- order-fingerprint gate: `:smalt_fond_seal.order_gate()` = :ok,
  sentinel fingerprint 628801 pinned

## Environment notes

Two transient shared-tree compile freezes from concurrent lanes
(`law_compiler.ex`, `journal_sink.ex`) were waited out with bounded 20 s
polls on `mix compile` (compile-freeze SLA; no edits to other lanes'
files). One pre-existing warning in the court file: `base` bound twice at
lines 218/223 — warning only, tests pass.

## Falsifier status

Falsifier did not fire: the always-412 run cannot complete, and it refused
typed rather than hanging (5 s skeptic timeout never observed).
