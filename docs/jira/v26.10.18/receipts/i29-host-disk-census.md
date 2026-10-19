# I29 Host Disk Census

- Date: 2026-10-18
Context: solo(read-only census + snapshot check; no deletions required)
- Standing: PASS (census complete; no action warranted on snapshots)

## Host free space

```
$ df -h /System/Volumes/Data
/dev/disk3s5   926Gi   859Gi    41Gi    96%    /System/Volumes/Data
```

41 Gi free (96% capacity). Tight but not exhausted.

## Step 2 — APFS local snapshot thinning

```
$ tmutil listlocalsnapshots /
com.apple.TimeMachine.2026-10-18-202734.local
com.apple.TimeMachine.2026-10-18-213514.local
com.apple.TimeMachine.2026-10-18-223512.local
```

All 3 snapshots are from today (2026-10-18); none older than 2 days.
Cleanup rule threshold (>2 days) met by zero snapshots — no
`tmutil deletelocalsnapshots` executed. Before/after free unchanged: 41 Gi.

## Step 3 — smalt build-dir census (report only, no deletion)

204 `_build*` roots totaling 25G. Largest (all ~697M each):

```
_build-lane13, _build-ft-str4, _build-ft-str3, _build-ft-str,
_build-ft-rep2, _build-ft-rep, _build-ft-pa, _build-ft-i29res,
_build-ft-fix2, _build-ft-cap1
```

Lane build roots are leases — deletion reserved for coordinator
`just lane-clean` at integration (backlog previously measured 168 roots /
~88 GiB; now 204 roots / 25G).

## Step 4 — tmp/ scratch (report only)

```
3.6G  /Users/sac/smalt/tmp
```

## Summary

- Snapshots thinned: 0 (none eligible)
- Host free: 41 Gi (96% used)
- Build roots: 204 dirs / 25G (untouched, lease law)
- tmp/: 3.6G (untouched)
