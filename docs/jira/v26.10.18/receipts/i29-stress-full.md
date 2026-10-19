# i29 — full stress suite (`mix test --include stress`)

Context: full (mix test --include stress)
Standing: **PARTIAL_ALIVE** — suite cannot go green this wave; 2 real deterministic failures + 1 compile-abort, remainder typed-classified as load/isolation flakes (pass in isolation).

## Command

```
MIX_BUILD_ROOT=_build-ft-str mix test --include stress
```

## Compile-abort (BLOCKED, pre-existing)

`test/azsim/sovereign_midnight/sovereign_midnight_test.exs:1` —
`Code.require_file("test/support/assert_eventually.ex", "/burn-evidence")` — hardcoded
nonexistent `/burn-evidence` root; identical defect class to the one fixed in commit
`dda0bf5` (`azure_common_issues require path`). Compile-abort, 0 tests executed in that
file; **excluded from the run** (`find test -name "*_test.exs" ! -path "*sovereign_midnight*"`).
Not fixed: lane mandate was no-edits.

## Full-suite run (excluding sovereign_midnight)

Full log: `/tmp/str-run.log` (scratch, not indexed).

```
Finished in 810.0 seconds (29.5s async, 780.4s sync)
1 doctest, 7 properties, 2742 tests, 7 failures, 1 invalid (61 excluded)
```

## Failure classification (each rerun in isolation)

| # | Test | Full-suite outcome | Isolated rerun | Class |
|---|---|---|---|---|
| 1 | `Smalt.SemconvReplayIdentityTest` registry replay | 300_000 ms `ExUnit.TimeoutError` in `run_mix/2` subprocess | PASS | LOAD-FLAKE — 5-min subprocess timeout exhausted under full-suite contention; not a drift defect (no mismatch reported) |
| 2 | `Smalt.Chaos.CrashIsolationTest` setup_all | `eventually("ARM listener answering")` not satisfied in 5000 ms after 28 passes | PASS | LOAD-FLAKE — listener-ready window under parallel-suite port contention |
| 3 | `SmaltTest.Azsim.DrScenariosTest` scenarios 1-4 (x10 each) | `{:error, :econnrefused}` / `:badarg` on `gen_tcp.connect` post-subtree-kill | PASS (all 10 scenarios) | LOAD-FLAKE — reconnect window; pass in isolation |
| 4 | `Smalt.StoreTablesReplayIdentityTest` `:smalt_` coverage | 2 atoms uncovered | FAIL (deterministic) | **REAL — swept-but-unowned**: `smalt_egress_guard`, `smalt_sb_` referenced in lib/ with no `smalt:StoreTable` row. Fix: ontology row + `mix smalt.gen` |
| 5 | `Smalt.EtsCompositeIdentityTest` composite lifecycle | residue | FAIL (deterministic) | **REAL — teardown residue**: reverse-topological teardown leaves `smalt_sb_messages` keys `{"resourcewritesuccess",1..5}` and `smalt_sb_queues` `{"resourcewritesuccess",:seq}` + queue row orphaned (EventGrid ResourceWriteSuccess events created during provision, never drained). Reproduces in isolation |
| 6 | `sovereign_midnight_test.exs` | compile-abort | n/a (compile-abort is not a failure count) | BLOCKED — require-path defect above |

## Isolated rerun (failing modules only)

```
MIX_BUILD_ROOT=_build-ft-str mix test test/semconv_replay_identity_test.exs \
  test/chaos/crash_isolation_test.exs test/smalt_ets_composite_identity_test.exs \
  test/store_tables_replay_identity_test.exs test/azsim/dr_scenarios_test.exs --include stress
→ 14 tests, 2 failures   (exit 2)
```

## Bottom line

- Green is NOT claimable. 2 deterministic failures (coverage sweep + ETS teardown residue)
  are the actionable surface; 5 full-suite-only failures are typed LOAD-FLAKE, each with an
  isolation PASS witness.
- The churn court calibration / fence-10/11/12 claims from the parent are untouched by this
  lane — no churn-court test appears in the failure set.
- Lane wrote no code, no shared-infra edits; only this receipt.
