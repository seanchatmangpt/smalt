# BK-126 — SPOF-4 receipt reconcile (post-BK-106 deadlock fix)

Date: 2026-10-22
Context: solo

## Standing

**Standing:** ALIVE (spof4-court 19/19 PASS, exit 0) — SPOF-4 tab-hardening receipt verified on disk, standing line current
post-deadlock-fix; spof4-court re-run post-fix: 19/19 PASS, exit 0.

## What was verified

1. `docs/jira/v26.10.22/receipts/spof4-tab-hardening.md` exists (8561 bytes,
   mtime 2026-10-21 21:43). Standing line (line 3):
   `Standing: **ALIVE** (all three SPOFs closed on HEAD; 19/19 spof4-court PASS, exit 0; ws-lint + ws-build green)`
2. Receipt-vs-BK-106 chronology: spof4 receipt mtime 21:43 predates
   `bk106-sync-engine-fixes.md` (22:44), and the receipt contains no mention of
   the deadlock or the `applySnapback` internal-ops change → it predates the
   SPOF-4.3 lease-nesting deadlock fix.
3. BK-106 receipt (`docs/jira/v26.10.22/receipts/bk106-sync-engine-fixes.md`)
   Fix 2 documents the repair: public LEASE-WRAPPED `snapbackStoreOps()` →
   `setCursor` → public `markSynced` was a nested same-client `navigator.locks`
   request deadlocking under real Web Locks; `applySnapback` now runs
   `snapbackWithStore(_snapbackStoreOps(), …)` and
   `_snapbackStoreOps().setCursor` calls raw `_markSynced(seq)`.

## Actions taken

- Appended a dated addendum to `spof4-tab-hardening.md` noting the deadlock
  repair landed via BK-106 (citing `bk106-sync-engine-fixes.md`) with the
  post-fix court re-run result.
- Re-ran the court post-fix.

## Verification outputs

```
$ cd /Users/sac/smalt/workspace && node scripts/spof4-court.mjs
# PASS: leg1: single fallback tab appends, leaseMode disclosed as fallback
# PASS: leg1: fallback append with live peer refused (phase SYNC_REFUSED_BY_SERVER)
# PASS: leg1: refused append minted NO seqId (store size unchanged)
# PASS: leg1: withWalLease fallback + peer typed-refuses PEER_TAB_ACTIVE
# PASS: leg1: read-only fallback body still runs beside a live peer
# PASS: leg1: after peer death, single-tab fallback append is allowed again
# PASS: leg2: master at seq 5 under web-locks
# PASS: leg2: survivor initialized at seq 5 (stale horizon reproduced)
# PASS: leg2: dead master advanced the store to seq 10 while survivor snapshot sat at 5
# PASS: leg2: survivor rehydrated — currentSeq advanced to the next free seq (11)
# PASS: leg2: survivor frames trail covers 1..11 after promotion
# PASS: leg2: survivor accumulatorRoot matches a full replay of all 11 stored frames
# PASS: leg2: unsyncedCount reflects the full un-acked horizon
# PASS: leg3: single-tab locked snapshot byte-identical semantics
# PASS: leg3: overlapping appends under one lease stay contiguous (4,5)
# PASS: leg4: needsRehydrate true only when store is ahead
# PASS: leg4: rehydratePlan maps hydration to the snapshot patch
# PASS: leg4: toSnapshotLeaseMode maps web-locks→locked, fallback→fallback
# PASS: leg4: initial snapshot discloses leaseMode unknown
# PASS: 19
# FAIL: 0
EXIT=0
```

Court run from `workspace/` cwd (repo-root tsc cannot resolve `--types node`).

Not committed, per work order.
