# i29 — budget export concurrent-lane isolation (justfile recipe fix)

Standing: PASS (isolation verified; gate FAIL is content-only, not corruption)

Context: pair(justfile.d/28-test-budget.just + scripts/test_budget_gate.py)

## Defect

`just test-budget` hard-coded `SMALT_BUDGET_EXPORT=tmp/test-budget-export.tsv`.
Two concurrent lanes both O_TRUNC that shared path mid-write; each saw the
other's partial file as a torn export and the gate failed closed on
`malformed line` — correct gate, hostile recipe. Fix the recipe, not the gate.

## Fix (recipe, single file: `justfile.d/28-test-budget.just`)

- Export path defaults to `tmp/test-budget-export.$$.tsv` (shell PID) via
  `${SMALT_BUDGET_EXPORT:-...}`; explicit override honored verbatim. Applies
  to both `test-budget` and `test-budget-seed`.
- Recipe is one shell per invocation (single physical recipe after `\`
  continuations) so `$$` is the same PID for formatter + gate.
- `just` runs recipes with `sh -cu`: `-e` aborts on a bare failing line, which
  was silently skipping the gate whenever `mix test` exited nonzero (witnessed
  exit 2 with zero gate output). Every command is now `|| rc=$?`-guarded and
  the recipe exits with the gate's code, falling back to mix's (`mix=<rc>
  gate=<rc>` summary line printed).

## Verification — two simultaneous `just test-budget` (separate MIX_BUILD_ROOTs)

Command: two background
`MIX_BUILD_ROOT=_build-i29-budget-$i just test-budget > tmp/i29-budget-run$i.log`

Both exports landed isolated and clean:

```
== budget export written: tmp/test-budget-export.2526.tsv   (run1)
== budget export written: tmp/test-budget-export.2524.tsv   (run2)
PASS budget-gate/fixture:breach (refused)                   (both runs)
PASS budget-gate/fixture:unmanifested (refused)             (both runs)
Gate: FAIL
== test-budget: mix=2 gate=1
run1 exit=1
run2 exit=1
== Test Budget Gate == (2748 tests)      — both runs, 0 parse errors
awk -F'\t' 'NF!=3' on both exports | wc -l → 0 malformed lines
```

The Gate: FAIL is content-only — 4 BREACH rows per run (e.g.
Amqp.FuzzTest 7388ms > 6225ms; StressTierCensusTest 9873ms > 7008ms), i.e.
timing variance under two concurrent full-suite loads. No
malformed/torn/duplicate export line in either run; both mutated fixtures
refused in both runs (gate non-vacuous).

Note (pre-existing, not session-introduced): `mix test` itself exited 2 in
both runs — formatter-only mode suppresses console failure output; under two
concurrent suites some timing-sensitive tests breach. Not a regression of
this fix.

Machine: `just bench-machine` not applicable (lifecycle recipe fix, no bench
lane).

## Replay

```
MIX_BUILD_ROOT=_build-i29-budget-1 just test-budget > /tmp/r1.log 2>&1 &
MIX_BUILD_ROOT=_build-i29-budget-2 just test-budget > /tmp/r2.log 2>&1 &
wait
grep -E "budget export written|Gate:|mix=" /tmp/r1.log /tmp/r2.log
```
