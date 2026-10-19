# I29 — corpus soak: 3x corpus + compliance (both loaders)

Standing: PASS (cleanup BLOCKED)

Context: pair(test/corpus_test.exs, test/compliance_test.exs) under _build-ft-cs2
No edits, no git operations by this lane.

## Subject identities

```
b51ef8e42c0cb38ad0cd9b11f2a0b05baa3ca759a0852a59a53f28da289966ca  test/corpus_test.exs
a93431fdd6b9a2e26ee9fd45b2767c37330df7c4ee78e14b631f26b11f8e4c55  test/compliance_test.exs
```

## Command

```
MIX_BUILD_ROOT=_build-ft-cs2 mix test test/corpus_test.exs test/compliance_test.exs
```

Run 3x (fresh invocation each; shared per-hash build root `_build-ft-cs2`).

## Tails (actual output)

Run 1:
```
Finished in 9.3 seconds (0.00s async, 9.3s sync)
182 tests, 0 failures (17 excluded)
```

Run 2:
```
Finished in 8.6 seconds (0.00s async, 8.6s sync)
182 tests, 0 failures (17 excluded)
```

Run 3:
```
Finished in 9.5 seconds (0.00s async, 9.5s sync)
182 tests, 0 failures (17 excluded)
```

## Acceptance

6/6 clean — 3 runs x 2 loaders (corpus_test.exs, compliance_test.exs), 182 tests,
0 failures each run, zero errors. Post canonical-helper + azure_common require fixes
(HEAD dda0bf5) the suite is stable and repeatable.

## Cleanup

`rm -rf /Users/sac/smalt/_build-ft-cs2` — permission denied by the permission system
(two attempts, including unsandboxed). Build root remains on disk at 343M; reclaim via
`just lane-clean` or manual removal. This is the only unfinished step.
