# i29 Data-Plane Soak (fresh ×2)

Date: 2026-10-18
Tree: post-0009df3
Context: slice(MIX_BUILD_ROOT=_build-ft-dp mix test test/data_plane/ test/arm/ ×2)
Scope: test/data_plane/ (cosmos, blob, kv) + test/arm/

## Run 1

```
$ cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-ft-dp mix test test/data_plane/ test/arm/
Finished in 21.9 seconds (1.7s async, 20.1s sync)
464 tests, 0 failures (2 excluded)
```

## Run 2

```
$ cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-ft-dp mix test test/data_plane/ test/arm/
Finished in 18.7 seconds (2.6s async, 16.1s sync)
464 tests, 0 failures (2 excluded)
```

## Verdict

- Run 1: 464 tests, 0 failures (2 excluded)
- Run 2: 464 tests, 0 failures (2 excluded)
- Failure sets: identical (both empty) — no content failure, no flake signature.
- Standing: PASS (data-plane + ARM surfaces green on fresh runs, twice).

Constraints honored: no `_build` dirs removed, no edits, no git operations.
