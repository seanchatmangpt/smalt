# i29 — fresh stress leg (churn court calibration + fence conversions)

Standing: BLOCKED[BUILD_BROKEN_TEST_COMPILE] — pre-existing, foreign-lane, same class as dda0bf5.

## Command

```
MIX_BUILD_ROOT=_build-ft-str2 mix test --include stress 2>&1 | tail -3
```

## Actual output (tail)

```
== Compilation error in file test/azsim/sovereign_midnight/sovereign_midnight_test.exs ==
** (Code.LoadError) could not load /burn-evidence/test/support/assert_eventually.ex. Reason: enoent
    (elixir 1.19.5) lib/code.ex:2339: Code.find_file!/2
    (elixir 1.19.5) lib/code.ex:1605: Code.require_file/2
    test/azsim/sovereign_midnight/sovereign_midnight_test.exs:1: (file)
```

## Classification

- **BLOCKED[BUILD_BROKEN_TEST_COMPILE]**: the stress suite cannot reach test
  execution; compilation aborts at `test/azsim/sovereign_midnight/sovereign_midnight_test.exs:1`
  — `Code.require_file("test/support/assert_eventually.ex", "/burn-evidence")`
  hard-codes a nonexistent `/burn-evidence` root. The real helper is
  `/Users/sac/smalt/test/support/assert_eventually.ex`.
- **Pre-existing, not session-introduced**: `test/azsim/sovereign_midnight/` is
  an untracked foreign-lane directory (git status `??`), not authored in this
  session. Zero edits, zero git operations performed by this lane.
- **Known defect class, recurrence**: the identical
  `/burn-evidence`-absolute-require defect was fixed in commit `dda0bf5`
  ("fix(test): azure_common_issues require path — __DIR__ relative, not
  nonexistent /burn-evidence") for `test/azure_common_issues`; the azsim lane
  re-introduced the pattern in a new file. The dda0bf5 fix did not fence the
  class, only the instance.
- This lane is a no-edit lane; repair is owned by the azsim/burn lane. Minimal
  fix: `Code.require_file("test/support/assert_eventually.ex", __DIR__ |> Path.join("../.."))`
  or `File.cwd!()`-relative require matching dda0bf5.

## Coverage note

Until the compile abort is repaired, `--include stress` execution is entirely
masked (0 stress tests executed — compile-abort, not a failure count; cf.
same-checkout-fanout addition 3 census-vs-compile-abort law). No stress-tier
pass/fail may be inferred from this leg.

## Machine

Solo lane on repo /Users/sac/smalt, branch main @ dda0bf5c504268a6d3b620c691520d97c1c384ac.

Lane cleanup: `_build-ft-str2` deleted after this receipt.
