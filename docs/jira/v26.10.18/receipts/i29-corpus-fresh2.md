# Receipt: corpus tier fresh ×3, post-0009df3

Date: 2026-10-18
Context: slice(mix test test/corpus_test.exs test/compliance_test.exs, 3 runs, private root _build-ft-cs4)
Subject: /Users/sac/smalt @ main, post-0009df3 (working tree, no git actions)
Standing: PASS

Scope: `MIX_BUILD_ROOT=_build-ft-cs4 mix test test/corpus_test.exs test/compliance_test.exs`
from /Users/sac/smalt, 3 consecutive runs, no cleanup between runs. Private build
root `_build-ft-cs4` left in place (not removed, per lane constraints).

Note: `just corpus-soak` exists (justfile.d/27-scratch-soak.just) but targets
`test/compliance_test.exs` only and `rm -rf _build-soak`s its build root — both
contrary to this lane's spec, so the tier was run directly, matching the prior
receipt i29-corpus-fresh.md invocation.

### Run 1
```
Finished in 19.9 seconds (0.00s async, 19.9s sync)
182 tests, 0 failures (17 excluded)
```

### Run 2
```
Finished in 24.0 seconds (0.00s async, 24.0s sync)
182 tests, 0 failures (17 excluded)
```

### Run 3
```
Finished in 15.0 seconds (0.00s async, 15.0s sync)
182 tests, 0 failures (17 excluded)
```

Acceptance: identical green counts all 3 runs — 182/182, 0 failures, 17 excluded
each run. No flakes, no errors. Wall times 15.0–24.0s (no sleep coordination).

Receipt chain: extends i29-corpus-fresh.md (same invocation, fresh root
_build-ft-cs3 → _build-ft-cs4, tree moved 0009df3+).
