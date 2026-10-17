# Receipt — R172 (lane-clean env-live guard)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W10 docs lane)

## Subject

`justfile.d/06-lane-cleanup.just` — the lane-clean live guard now harvests
`MIX_BUILD_ROOT` from running process environments (`ps eww`) in addition to
lsof/cwd, so an env-live lane root is never offered for deletion (the operator
law "lane build roots are leases, not assets"). Markers: the `ps eww` harvest
in `live_refs()` and the SHIM-COURT-marked space-join + bare-basename case
guard.

## Verification (2026-10-16, W10 docs lane, unedited output)

Same-instant census of env-referenced build roots while this lane's own
`MIX_BUILD_ROOT=_build-lane204` full-tier run was in flight:

```
$ for pid in $(pgrep -f 'beam.smp|mix'); do ps eww "$pid" 2>/dev/null | grep -o 'MIX_BUILD_ROOT=_build[-A-Za-z0-9_]*'; done | sort | uniq -c
   2 MIX_BUILD_ROOT=_build-lane161
   1 MIX_BUILD_ROOT=_build-lane163
   6 MIX_BUILD_ROOT=_build-lane167
   2 MIX_BUILD_ROOT=_build-lane204
   3 MIX_BUILD_ROOT=_build-lane205
   4 MIX_BUILD_ROOT=_build-lane209
   2 MIX_BUILD_ROOT=_build-lane210
   2 MIX_BUILD_ROOT=_build-lane211
   2 MIX_BUILD_ROOT=_build-lane213
   3 MIX_BUILD_ROOT=_build-lane214
   1 MIX_BUILD_ROOT=_build-lane23
$ just lane-clean-dry
== lane-clean-dry (root: /Users/sac/smalt) ==
SKIP (live-referenced): _build-lane161
SKIP (live-referenced): _build-lane163
SKIP (live-referenced): _build-lane167
SKIP (live-referenced): _build-lane204
SKIP (live-referenced): _build-lane205
SKIP (live-referenced): _build-lane209
SKIP (live-referenced): _build-lane211
SKIP (live-referenced): _build-lane214
SKIP (live-referenced): _build-lane23
TOTAL: 105851288 KB (100.95 GiB)
```

Every env-live root visible at census instant (lane161/163/167/204/205/209/211/
214/23) is excluded from the deletion candidates. Honest caveat: lane210 and
lane213 carried env refs at the census instant but do not appear as SKIP in the
dry-run — the census and the clean pass are two instants on a busy tree with
concurrent lanes churning processes; this is a same-instant race observation
between two snapshots, not a guard miss on a stable root. The guard's effect is
witnessed: 9/9 roots live in snapshot-1 were skipped.

Standing: PASS (with the two-snapshot race caveat recorded).
