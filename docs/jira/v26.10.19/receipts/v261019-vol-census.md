# Receipt — V261019-FIN (test-volume census)

Context: solo(V261019-FIN) — all numbers below are output of commands run by
this lane at the working tree, 2026-10-19.
Standing: **CENSUS-PARTIAL** — external suite leaves (node:test, pytest
"before") are grep-censused, not executed; every number cites its command.
Base: main @ 64f6099 (143 dirty paths, shared checkout)
Date: 2026-10-19

## Commands and real output

### ExUnit after (executed)

```
$ MIX_BUILD_ROOT=_build-lane-fin mix test   (tail)
...
Finished in 2.1 seconds (0.1s async, 2.0s sync)
20 tests, 0 failures
exit=0
```

20 leaves, matching V261019-10 (`v261019-10-residual-elixir-tier.md`,
ALIVE, 20 tests / 0 failures). Also matches the after-side of
V261019-RC (`v261019-rc-rewrite-census.md`).

### ExUnit before (census, at 64f6099~1 = pre-deletion tree)

```
$ git ls-tree -r --name-only 64f6099~1 -- test/ | wc -l
303
$ git ls-tree -r --name-only 64f6099 -- test/ | wc -l
1                      # test/test_helper.exs only
$ git grep -h -E '^[[:space:]]*test "' 64f6099~1 -- 'test/*.exs' | wc -l
2610
$ git diff --stat 64f6099~1 64f6099 -- test/ | tail -1
 303 files changed, 5 insertions(+), 107644 deletions(-)
```

Executed before-leaf baseline (manifest era): **2,763 budgeted ExUnit
leaves** — `python3 -c "import json;d=json.load(open('docs/jira/v26.10.18/test_budgets.json'));print(len(d['budgets']))"`
→ `2763`. This is the manifest-era figure carried by
`docs/jira/v26.10.18/test_budgets.json`, the ≥80% target's named baseline.

**Note on "83,183"**: the task brief's "83,183-line figure" does NOT appear
anywhere on disk (`grep -rn "83,183" docs/ .` → zero matches). The real
deletion receipt figure is **107,644 lines deleted / 303 files**
(`docs/jira/v26.10.19/receipts/v261019-11-test-deletion-gate.md`,
`reset-delete-manifest.txt` = 303 lines, wc -l verified). The census uses
the on-disk figures.

### pytest

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/ smalt_cli/ --collect-only -q | tail -2
smalt_cli/test_policy.py::test_guard_passes_through_on_read
150 tests collected in 0.56s
```

After = **150 collected** (executed collection, real pytest).
Before = **156** `def test_` definitions at 64f6099~1:

```
$ git grep -c "def test_" 64f6099~1 -- smalt-cli | awk -F: '{s+=$NF} END{print s}'
156
```

### node:test leaves (grep census, both sides — suites NOT executed)

Method: top-level leaf calls, anchored `^[[:space:]]*(it|test)(`, over
`workspace/test/*.test.ts` + `workspace/test/*.mjs`, node_modules excluded.
Looser unanchored counts (98 before / 98 after) include `.test(` regex
false positives (e.g. RegExp `.test(` in `verification/ts/wf*/index.ts` —
those files contain zero `node:test` imports, verified:
`grep -rn "node:test" verification/ts --exclude-dir=node_modules` → 0).

```
$ git grep -h -E '^[[:space:]]*(it|test)\(' 64f6099~1 -- 'workspace/test/*.test.ts' 'workspace/test/*.mjs' | wc -l
97
$ grep -rEn '^[[:space:]]*(it|test)\(' workspace/test --include='*.test.ts' --include='*.mjs' | wc -l
97
```

Before = after = **97** — the workspace external surface was untouched by
the reset; its reduction is 0%.

### Harness exits

Not executed this window (no harness run by this lane; no sibling run
cited). Row marked n/a rather than asserted.

## Reduction arithmetic (before − after) / before

| Line | Before | After | Reduction | ≥80% target |
|---|---|---|---|---|
| Tracked test files | 303 | 1 | 99.7% | **MET** |
| ExUnit leaves | 2,763 (budgeted baseline) | 20 (executed) | 99.3% | **MET** |
| pytest items | 156 (grep) | 150 (collected) | 3.8% | **NOT MET** |
| node:test leaves | 97 (grep) | 97 (grep) | 0% | NOT MET (untouched) |
| harness exits | n/a | n/a | — | not executed |
| **All-harness leaf total** | 3,016 | 267 | **91.1%** | **MET (leaf-weighted)** |

Leaf-level is PARTIAL: the aggregate clears 80% only because the ExUnit
reset dominates the leaf population; the pytest and node:test surfaces were
scoped out of the deletion and are carried open into the next window.

## Deviations / disclosure

1. `_build-lane-fin` build root created by this lane's `mix test` run;
   deletion attempt was permission-denied in this lane — left for
   coordinator `just lane-clean` per the cleanup law.
2. "Harness exits" row carries no number — no execution, no assertion.
