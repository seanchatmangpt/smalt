# Receipt — V261019-RC (rewrite-census: test-volume before/after)

Context: solo(V261019-RC) — census greps + the residual-tier run executed by
this lane, 2026-10-19 ~10:08–10:12 PDT; suite runs not executed.
Standing: **PARTIAL** — the ExUnit row and the deletion delta are executed
numbers from this session; the node:test / pytest rows are censused
(file/test-function greps) but NOT executed (no suite runs this window);
court tally not executed. The ≥80% arithmetic is NOT computed — two of four
rows lack executed counts, and computing a ratio over censused-only rows
would be an unreceipted assertion. Refresh 2026-10-19 (final-docs lane):
ExUnit after-count re-executed full-suite at HEAD `81a7a29` → 31 tests,
0 failures; `git ls-files test/` = 9. Two rows remain censused-only.
Base: 64f6099663a4ec32fd9478c4c39fca49ab1961f8 (shared checkout, 143 dirty paths)
Date: 2026-10-19

## What changed

- Before/after census across the four harnesses. "Before" = pre-`64f6099`
  tree (303 deleted test files, 107k lines — `git show --stat`); "after" =
  current tree.

| Harness | Leaf unit | Before | After | Δ |
|---|---|---|---|---|
| ExUnit | `test` leaves | 107k lines / **303 files deleted → 9 tracked files remain** (pre-deletion run counts in git history only) | **31 tests, 0 failures** (executed: final-docs lane, HEAD `81a7a29`) | -303 files → 9 remain |
| node:test | suite leaves | 0 (surface deleted) | **0 executed leaves**; `verification/ts/` exists (wf1..wf5 + harness) but 0 `*.test.*` files | — |
| harness exits | typed harness exits | n/a | not executed this window | — |
| pytest | collected items | 0 (surface deleted) | **38 `def test_` items across 5 files** (censused, not collected/executed) | — |

## Verification (real output tails)

```
$ MIX_BUILD_ROOT=_build-lane-rc1 mix test test/internal/   (tail)
......
Finished in 1.9 seconds (0.1s async, 1.8s sync)
20 tests, 0 failures
exit=0
```

Refreshed after-count (final-docs lane, 2026-10-19, HEAD `81a7a29`):

```
$ MIX_BUILD_ROOT=_build-lane-final1 mix test   (tail)
Finished in 2.4 seconds (0.1s async, 2.2s sync)
31 tests, 0 failures
exit=0
```

```
$ git ls-files test/ | wc -l
9
```

```
$ find verification/ts -name "*.test.*" -not -path "*/node_modules/*" | wc -l
0
```

```
$ grep -rn "def test_" verification/py/ | wc -l
38
```

```
$ git show --stat 64f6099 | grep -c "^ test/"   # deletion side (from manifest)
303 files changed (see reset-delete-manifest.txt, 303 lines — wc -l verified)
```

## ≥80% arithmetic

NOT COMPUTED. The ExUnit executed count (31, refreshed 2026-10-19 at HEAD
`81a7a29`; 9 tracked `test/` files) and the pytest censused count
(38) are real, but the census table requires executed after-counts for all
four harnesses against executed before-counts at one SHA; the pre-deletion
per-leaf counts are recoverable only from git history (`git show 64f6099^`),
which is a separate execution. No ratio is asserted. This is the census's
open remainder, coupled to V261019-11's deletion gate.

## Acceptance greps

- `grep -c "TBD" docs/jira/v26.10.19/receipts/v261019-rc-rewrite-census.md`
  => 0 (this file carries no TBD tokens; the incompleteness is stated in
  prose with the exact missing executions, not hidden behind placeholders).
- Cross-check: the ExUnit after-count (20 at the RC lane's run) was the
  same tier recorded in `v261019-10-residual-elixir-tier.md`; the refreshed
  full-suite run (31) covers the whole tracked `test/` tree (9 files).

## Deviations

1. Skeleton's node:test command (`node --test workspace/test/`) and pytest
   command (`smalt-cli` venvs) reference pre-reset surfaces; post-reset
   surfaces are `verification/ts` and `verification/py`. Recorded as a
   measured deviation.
2. Standing PARTIAL, not ALIVE: two of four rows are censused-only. Flip to
   ALIVE requires: pytest `--collect-only` executed, a node:test executed
   run (currently impossible — zero `.test.ts` leaves exist), the
   `git show 64f6099^` before-counts, and the ratio computation.
