# Receipt: i29-corpus-fresh3 — corpus soak ×3 at HEAD ≥ d1298be

- Date: 2026-10-18
- Context: slice(corpus ×3)
- Subject: /Users/sac/smalt @ d1298be513121ac1828b44b13eb77b8a084c7f75 (main)
- Command (run 3× from repo root):

```bash
git log -1 --format=%H
# d1298be513121ac1828b44b13eb77b8a084c7f75
MIX_BUILD_ROOT=_build-ft-cs5 mix test test/corpus_test.exs test/compliance_test.exs
```

## Results

| Run | Result | Excluded |
|---|---|---|
| 1 | 182 tests, 0 failures | 17 |
| 2 | 182 tests, 0 failures | 17 |
| 3 | 182 tests, 0 failures | 17 |

Identical green counts across all 3 runs; matches prior 182/0 ×3 baseline.

Timings: 17.8s / 32.0s / 18.1s.

## Standing

PASS — acceptance met (identical 182/0 ×3 at HEAD d1298be). No edits, no git
transitions, no `_build` deletion performed by this lane.
