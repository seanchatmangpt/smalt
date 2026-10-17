# R76: court_x2 judge_log compile-abort guard

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `scripts/court_x2.sh` (judge_log() landed in working tree)

## Claim

Fixes the r35 FAIL WITNESS: the green predicate grepped the literal
`== Compilation error ==` which never matches real mix output
(`== Compilation error in file ... ==`), so a compile-aborted run judged GREEN vacuously.
The landed judge_log greps the prefix `== Compilation error` plus a nonzero-failures
exclusion.

## Re-run evidence (A/B/C witness over the exact landed predicate)

```
$ cat > j_green.log  # '.......... / 0 failures'
$ cat > j_fail.log   # '1) test x ... 3 failures'
$ cat > j_comp.log   # '== Compilation error in file lib/smalt/x.ex =='
$ for f in j_green j_fail j_comp; do
    if grep -Eq '0 failures' $f.log && ! grep -Eq '[1-9][0-9]* failures?' $f.log \
       && ! grep -q '== Compilation error' $f.log && ! grep -q ' compilation failed' $f.log; then
      echo "$f: GREEN"; else echo "$f: NOT-GREEN"; fi; done
j_green: GREEN
j_fail: NOT-GREEN
j_comp: NOT-GREEN
```

## Verdict

PASS. Green/fail/compile-abort all judged correctly; the compile-abort arm matches real
mix phrasing, closing the r35 defect. Full court_x2 (~8 min) not re-run in this lane; the
predicate itself is what r35 flagged.
