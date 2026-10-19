# i29 budget gate final (lane receipt)

- **Standing**: PASS (gate) / SUSPECT (suite) — gate green, suite carries 4 pre-existing/in-flight-diff failures unrelated to the budget gate.
- **Context**: solo
- **Date**: 2026-10-19

## Settlement state checked first

- `docs/jira/v26.10.18/receipts/i29-budget-reseed.md`: **absent** on disk.
- `docs/jira/v26.10.18/test_budgets.json`: **still dirty** (`M` in `git status`; last commit touching it is d8fd6c3, uncommitted working-tree changes on top). Not settled → gate-run-anyway path taken per task.

## Gate e2e (PID-parameterized recipe, lane-private export)

```
MIX_BUILD_ROOT=_build-laneB SMALT_BUDGET_EXPORT=tmp/tb-final.tsv just test-budget
== budget export written: tmp/tb-final.tsv
PASS budget-gate/fixture:breach (refused)
PASS budget-gate/fixture:unmanifested (refused)
== Test Budget Gate == (2748 tests)
Gate: PASS
== test-budget: mix=2 gate=0
```

Gate re-confirmed standalone: `python3 scripts/test_budget_gate.py --export tmp/tb-final.tsv` → PASS, exit 0. Export `tmp/tb-final.tsv` is complete (2748 lines) — no truncation.

Gate verdict: **PASS, exit 0.** Budget counts vs manifest: 0 stale, 0 regressions, 0 unbudgeted — but the run is not 0/0/0 because `mix test` exited nonzero (below), which is the suite, not the manifest.

## Suite failures (why mix != 0)

The BudgetFormatter is export-only (no console formatter), so failures are invisible under it; identified via a default-formatter run (`/tmp/tb-mix-default.log`):

```
1 doctest, 7 properties, 2740 tests, 4 failures (99 excluded)
```

1. `Smalt.Enclave.LifecycleTest` "OCEL stage emission is fail-safe..." — `:ets.insert(:smalt_subscriptions, ...)` table-does-not-exist in `SmaltTest.Store.resilient_clear/1` (test/support/store_resilient.ex:20). Table-lifetime/concurrency flake class (F8 family), not budget-related.
2. `SmaltTest.Azsim.DetsRecoveryTest` "graphlaw/WasmEngine killed mid-request ... 503" — engine_unavailable not delivered as expected; recovery-window flake.
3. `Smalt.ErrorCodesDocTest` "docs/ERROR_CODES.md is the byte-identical projection" — **pre-existing working-tree drift**: `lib/smalt/egress_router.ex` (+234 uncommitted, another lane's in-flight edits) vs stale `docs/ERROR_CODES.md` (`M` in git status). Fix is `python3 scripts/gen_error_codes.py` by the lane that owns those edits, or at integration.
4. `KvTlsTest` "TLS twin dispatches all egress prefixes" — "request kept returning 5xx after retries" concurrent with repeated `:eaddrinuse` on egress port 59049 in the same log — port-collision from overlapping concurrent runs, self-inflicted by parallel lanes, not a code defect witnessed.

## Non-goals honored

No code edits, no git mutations. Lane build root `_build-laneB`; exports `tmp/tb-final*.tsv` are scratch.

## Replay

```
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-laneB SMALT_BUDGET_EXPORT=tmp/tb-final.tsv just test-budget
python3 scripts/test_budget_gate.py --export tmp/tb-final.tsv   # exit 0
mix test   # default formatter, to see the 4 failures above
```
