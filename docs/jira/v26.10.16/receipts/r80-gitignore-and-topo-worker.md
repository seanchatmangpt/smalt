# Receipt — R80 (.gitignore bench dirs + topo-worker inline poll)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `.gitignore:84-85` — R80: `workspace/.bench/` and `workspace/bench_results/`
  ignored
- `workspace/lib/bench/topo-worker.ts:83`/`:91` — dead `setInterval` replaced
  with an inline poll (event-loop-safe, `allocatedBytes` carried in the poll
  sample)

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ git check-ignore -v workspace/.bench/x workspace/bench_results/x; echo CHECK=$?
.gitignore:84:workspace/.bench/	workspace/.bench/x
.gitignore:85:workspace/bench_results/	workspace/bench_results/x
CHECK=0

$ grep -n "setInterval\|allocatedBytes" workspace/lib/bench/topo-worker.ts
83:    // event loop, so setInterval callbacks would never fire.
91:        allocatedBytes: lastAllocBytes,
```
