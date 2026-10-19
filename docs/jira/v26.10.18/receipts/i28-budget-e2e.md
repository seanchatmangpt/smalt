# i28 — Budget gate end-to-end verification (solo)

Date: 2026-10-18. Standing: PASS (with one operator-contract finding, below).

## Scope

Verify the per-test timing budget gate end-to-end on the current tree:
produce a real timing export, inspect its shape, run
`scripts/test_budget_gate.py` against the seeded manifest
`docs/jira/v26.10.18/test_budgets.json`. No edits, no git.

## Step 1 — Export production (with a correction to the given recipe)

The dispatched command (`SMALT_BUDGET_EXPORT=... mix test test/smalt_test.exs
test/policy_rbac_test.exs`, no formatter flag) produced NO export:
`ls /tmp/budget-export.tsv -> No such file or directory`. The env var only
sets the output path — the formatter must be selected explicitly. Per
`justfile.d/28-test-budget.just` and the draft
(`docs/jira/v26.10.18/rewrite-drafts/budget-gate.md`), the export-only run is:

```
$ SMALT_BUDGET_EXPORT=/tmp/budget-export.tsv MIX_BUILD_ROOT=_build-ft-bg \
    mix test --formatter SmaltTest.BudgetFormatter \
    test/smalt_test.exs test/policy_rbac_test.exs 2>&1 | tail -3
21:16:44.920 [info] Sent 200 in 188µs
== budget export written: /tmp/budget-export.tsv
exit=0
-rw-r--r--  1 sac  wheel  2224 Oct 18 21:16 /tmp/budget-export.tsv
```

Suite result: `1 doctest, 13 tests, 0 failures`.

**Finding (operator contract)**: `SMALT_BUDGET_EXPORT` alone does not activate
exporting; `--formatter SmaltTest.BudgetFormatter` is required (the formatter
is export-only, no console formatter, per the draft's land-lane fallback).
The canonical recipes are `just test-budget` / `just test-budget-seed`.

## Step 2 — TSV shape

14 lines, every line exactly 3 tab-separated fields
(`awk -F'\t' '{print NF}' | sort | uniq -c` -> `14    3`):

```
/Users/sac/smalt/test/smalt_test.exs:3	0	Elixir.SmaltTest.doctest Smalt.hello/0 (1)
/Users/sac/smalt/test/smalt_test.exs:5	0	...test greets the world
/Users/sac/smalt/test/policy_rbac_test.exs:180	190	Elixir.Smalt.PolicyRbacTest.test role assignments (RBAC) built-in roleDefinitions served by name and by GUID (Owner/Contributor/Reader)
/Users/sac/smalt/test/policy_rbac_test.exs:294	396	Elixir.Smalt.PolicyRbacTest.test policy enforcement on resource PUT audit effect records non-compliance but allows the PUT
...10 more PolicyRbacTest rows, durations 0-396 ms
```

## Step 3 — Gate run (partial export vs full manifest)

```
$ python3 scripts/test_budget_gate.py --export /tmp/budget-export.tsv --manifest <default seeded manifest>
PASS budget-gate/fixture:breach (refused)
PASS budget-gate/fixture:unmanifested (refused)
== Test Budget Gate == (14 tests)
  STALE <test>: in manifest but absent from export   x 2011
Gate: FAIL
exit=1
```

Verdict: **FAIL, exit 1** — and this is the CORRECT verdict for a partial
export against the full manifest. The gate does NOT emit `UNMANIFESTED` for
this run: all 14 export rows matched manifest entries (each
`{"tier": "default"}`, verified programmatically), so the failure is entirely
STALE-class (2011 rows: manifest entries with no export line — the tests did
not run in this small suite). Fail-closed held: the partial-export case is a
typed refusal, not a silent pass. Both non-vacuity fixtures refused (gate not
vacuous). Note: the gate is positional-arg-strict (`unrecognized arguments`)
— use `--export PATH`.

## Falsifier status

- Env-var-only run leaves no export (witnessed above) — recipes must carry
  `--formatter SmaltTest.BudgetFormatter`.
- Partial export + full manifest -> typed STALE refusal, exit 1 (witnessed).
- Non-vacuity: breach and unmanifested-rename fixtures both REFUSED (witnessed).
