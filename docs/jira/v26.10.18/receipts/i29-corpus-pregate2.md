# i29 — corpus re-soak ×2 pre-gate (post azb-20 lib landing wave)

Date: 2026-10-19
Context: solo
Subject: /Users/sac/smalt @ main (post azb-20 data-plane lib landing wave; tree has in-flight lane edits, untouched by this lane)

## Command

```
MIX_BUILD_ROOT=_build-ft-cs8 mix test test/corpus_test.exs test/compliance_test.exs
```

Run 1 output (tail):

```
Finished in 9.8 seconds (0.00s async, 9.8s sync)
182 tests, 0 failures (17 excluded)
```

Run 2 output (tail):

```
Finished in 8.9 seconds (0.00s async, 8.9s sync)
182 tests, 0 failures (17 excluded)
```

## Result

| run | tests | failures | excluded |
|---|---|---|---|
| 1 | 182 | 0 | 17 |
| 2 | 182 | 0 | 17 |

Matches baseline 182/0. No edits, no git ops, no build-root deletion.

Standing: PASS (×2, deterministic).
