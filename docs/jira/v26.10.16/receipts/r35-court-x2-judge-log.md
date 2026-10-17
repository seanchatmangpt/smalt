# Receipt — R35 (court_x2 green predicate A/B: compile-abort must judge NOT-GREEN)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave W2)
- **Standing:** FAIL WITNESS — predicate defect found by this receipt's own court
- **Date:** 2026-10-15 (witnessed by W2 docs lane)

## Subject files

- `scripts/court_x2.sh` — `summary_of` replaced by `judge_log()`: "0 failures"
  with no nonzero-failure count AND no compile-abort marker.

## Court (2026-10-15, W2 docs lane, unedited output; function sourced verbatim from scripts/court_x2.sh)

```
$ sed -n '/^judge_log/,/^}/p' scripts/court_x2.sh > /tmp/jl.sh && bash -c '
source /tmp/jl.sh
printf "Random seed: 1\n192 tests, 0 failures, 3 skipped\n" > /tmp/jl-green.log
printf "192 tests, 2 failures\n" > /tmp/jl-fail.log
printf "== Compilation error in file lib/x.ex ==\n** (CompileError) cannot compile\n0 failures\n" > /tmp/jl-comperr.log
... judge_log over the three fixtures ...'
log1: GREEN
log2: NOT-GREEN
log3: GREEN          <-- DEFECT
```

```
$ bash -c 'source /tmp/jl.sh; printf "== Compilation error ==\n0 failures\n" > /tmp/jl-comperr-lit.log; judge_log /tmp/jl-comperr-lit.log || echo NOT-GREEN'
exact-literal compile-error log: NOT-GREEN
```

## Defect (open)

The compile-abort guard greps the literal `'== Compilation error =='`, but
real mix output is `== Compilation error in file lib/x.ex ==` — the literal
never matches, so a compile-aborted run whose log contains "0 failures"
still judges GREEN (the exact vacuous pass R35 was meant to kill). The guard
fires only for the exact-literal form (proved above). Fix belongs to the
court_x2-owning lane: widen the pattern (e.g. `'== Compilation error'`).
No code change made by this lane (docs scope).
