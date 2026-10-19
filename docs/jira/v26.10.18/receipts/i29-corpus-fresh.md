# i29 — fresh-build corpus soak (bench-runner, slice context)

Standing: PASS (3/3 clean, 182/0 class)

Subject: smalt HEAD `dda0bf5c504268a6d3b620c691520d97c1c384ac`, private build root `_build-ft-cs3` (fresh compile, no shared `_build` reuse).

Scope: `MIX_BUILD_ROOT=_build-ft-cs3 mix test test/corpus_test.exs test/compliance_test.exs`, 3 runs at HEAD.

## Results

| run | tests | failures | excluded | wall |
|---|---|---|---|---|
| 1 | 182 | 0 | 17 | 21.4s |
| 2 | 182 | 0 | 17 | 14.1s |
| 3 | 182 | 0 | 17 | 16.2s |

Acceptance: 3/3 clean runs, 182/0 every run. Met.

Sample run output:

```
Finished in 16.2 seconds (0.00s async, 16.2s sync)
182 tests, 0 failures (17 excluded)
```

No edits, no git operations. Build root `_build-ft-cs3` removed after runs (lane lease cleanup law).

Machine: darwin (macOS 25.2.0, arm64 host).
