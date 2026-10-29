# SPOF-4 — Browser-tab hardening (fallback peer guard, rehydrate-on-promotion, leased surface)

**Standing:** **ALIVE** (all three SPOFs closed on HEAD; 19/19 spof4-court PASS, exit 0; ws-lint + ws-build green)
Date: 2026-10-21
Repo: /Users/sac/smalt @ main (dirty tree; changes left uncommitted per work order)
Context: solo

Targets: `workspace/lib/engine/{tab-lease,journal-sync,useJournal}.ts`
Audit source: `docs/jira/v26.10.22/receipts/spofb-boundary-audit.md` vector 4.

---

## SPOF-4.1 — fallback is no longer silent multi-tab corruption

* **Fix**: `workspace/lib/engine/tab-lease.ts`
  * New `PeerGuard` (BroadcastChannel ping/pong, channel literal
    `lawinput_wal_peer`): each guard announces itself on construction and
    answers pings with pongs; `hasLivePeer()` pings and polls pong arrival
    within a bounded 50 ms window (bounded poll on a real observable, no
    fixed settle sleep), prunes peers stale > 2 s.
  * `withWalLease` gains `refuseFallbackWithPeers` + `peerGuard` + `onAcquired`
    options. In fallback mode with `refuseFallbackWithPeers`, a live peer
    tab refuses the body typed: `PEER_TAB_ACTIVE` (new `WalLeaseError` and
    `JournalError` variants, carrying the peer tab ids).
  * `journal-sync.appendLocal` is now the lease-wrapped public path and sets
    `refuseFallbackWithPeers: true` — appends never double-mint seqIds in
    fallback beside a live peer. Read-only bodies (drain, reads) do not set
    the flag, so a live peer does not block reads.
  * Snapshot surface: `JournalSnapshot.leaseMode: "locked"|"fallback"|"unknown"`
    (new `SnapshotLeaseMode` + `toSnapshotLeaseMode` in tab-lease), patched
    on every lease acquisition via `onAcquired`; initial snapshot is
    `"unknown"`.
  * Single-tab fallback stays allowed, degraded — disclosed by
    `leaseMode: "fallback"` on the snapshot.
* **Court (leg 1)**: no LockManager installed (fallback), two engines with
  real node `BroadcastChannel` guards: tab A appends (fallback disclosed),
  tab B append → phase `SYNC_REFUSED_BY_SERVER`, store size unchanged (no
  seqId minted); wrapper-level `withWalLease` refusal typed
  `PEER_TAB_ACTIVE` with `peers:["tab-a"]`; read-only body beside a live
  peer still runs; after peer death a fresh solo tab appends again.
* **Pre-fix falsifier run**: not captured pre-edit (fix and court landed in
  the same session; leg-1's stale-horizon precondition assert in leg 2
  reproduces the audit's failure scenario against the new guard).

## SPOF-4.2 — rehydrate on lease acquisition (master death → horizon transfers)

* **Fix**: `workspace/lib/engine/journal-sync.ts` + `useJournal.ts`
  * Pure/IDB split, both node-testable: `needsRehydrate(currentSeq, storeMaxSeq)`
    and `rehydratePlan(hydrated, ackCursor)` are exported pure functions;
    the IDB side rides the existing `hydrate()`/`nextSeqId()`/`syncedCursor()`.
  * `withWalLease` gains `onAcquired` (fires after grant — including the
    initial acquisition — before the body; also fires in fallback mode).
  * `JournalSyncEngine` rehydrates inside `onAcquired`: if the store's max
    seqId exceeds the snapshot's `currentSeq` (`needsRehydrate`), re-run the
    hydration math (`hydrate()` → PAT-A `nextSeqFromSegments`/`countUnsynced`)
    and rebuild the accumulator by full frame replay (`rehydratePlan` +
    fresh `Accumulator`) BEFORE the leased body serves. Rehydrates are
    serialized per engine (`this.rehydrating` promise chain).
  * `init()` refactored to share `rebuildFrom()` — idempotent replay.
* **Court (leg 2)**: master appends 1..5; survivor inits at 5 (stale horizon
  reproduced explicitly); master appends 6..10 and "dies" (lock released);
  survivor's next leased append re-acquires → rehydrate → `currentSeq` 11,
  frames `1..11`, `unsyncedCount` 11, and `accumulatorRoot` equals a
  ground-truth full replay of all 11 stored frames.
* **Falsifier check**: the audit's failure ("B shows currentSeq=5 and a
  stale root") is asserted as the PRE-conditions in leg 2 (survivor at 5
  while store at 10) — post-fix the promotion rebuilds to 11 with the
  correct root. A pre-fix engine fails leg 2 at the currentSeq assert.

## SPOF-4.3 — the lease-wrapped module surface is the only public path

* **Fix**: raw ops underscore-prefixed (internal), public
  exports lease-wrapped in journal-sync:
  * `_appendLocal` / `_markSynced` / `_snapbackStoreOps` / `_flushSync` /
    `applySnapback` are internal (no lease of their own; callers hold it).
  * Public `appendLocal(opts?)`, `markSynced(opts?)`, `snapbackStoreOps(opts?)`,
    `flushSync(opts?)` each run under `withWalLease` via the `leased`/`leasedLoose`
    helpers, threading `onAcquired`/`peerGuard`.
  `useJournal.ts` no longer wraps with `withWalLease` itself — the engine is
  now a pure consumer of the leased surface (its `unwrapLease` helper
  deleted); internal `flushSync` body uses `_markSynced`.
  Grep receipt: only comment references remain outside the three files
  (`app/terminal/page.tsx` comment, snapback.ts docstring).
* **Court (leg 3, regression)**: single-tab locked path — init + 3 appends
  produce the identical snapshot semantics (ready/phase/currentSeq/frames/
  unsyncedCount/`leaseMode:"locked"`/root = full replay), and overlapping
  appends stay contiguous (4,5) under the lease.

## Court transcript (scripts/spof4-court.mjs, real run)

Compiles the real engine closure (tab-lease, journal-sync, useJournal +
codec/snapback/receipt/merkle) with the workspace tsc to a private temp
dir, over REAL collaborators: hand-written FIFO-mutex LockManager, a
hand-written IndexedDB (Maps) implementing the exact request/tx surface
journal-sync uses, and node's real BroadcastChannel for PeerGuard.

```text
$ node scripts/spof4-court.mjs; echo "exit=$?"
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
# PASS: leg2: survivor frames trail covers 1..9,10,11 after promotion
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
exit=0
```

## Gates (real runs, this session)

| gate | command | verdict |
|---|---|---|
| spof4 court | `node scripts/spof4-court.mjs` | 19 PASS / 0 FAIL, exit 0 |
| tab-lease court (regression) | `node scripts/tab-lease-court.mjs` | 7 PASS / 0 FAIL, exit 0 |
| dom-contract court | `node scripts/dom-contract-court.mjs` | PASS (0 failures), exit 0 |
| pattern court | `node scripts/pattern-court.mjs` | 13 PASS / 3 SKIP / 0 FAIL, exit 0 |
| lint | `just ws-lint` | 0 errors (43 pre-existing warnings), exit 0 |
| build | `just ws-build` | Next build green, exit 0 |

## Standing notes / residual

* BroadcastChannel-absent runtimes (SSR, old browsers): PeerGuard degrades
  to "no peers observed" — fallback appends proceed single-tab, disclosed
  via `leaseMode: "fallback"`. Detection is best-effort by design; the
  locked path never relies on it.
* `rehydratePlan` carries a typed precondition (`unsyncedCount` cannot
  exceed stored frames) — a corrupted hydration vector refuses loudly.
* Pre-fix falsifier runs of legs 1/2 were not captured (fix and court in
  the same session); leg 2 explicitly asserts the audit's stale-horizon
  precondition (survivor at 5, store at 10) before the promotion rebuild.
* Not committed, per work order. Changed files:
  `workspace/lib/engine/{tab-lease,journal-sync,useJournal}.ts`,
  `workspace/scripts/spof4-court.mjs` (new), this receipt.

## Addendum (2026-10-22) — SPOF-4.3 lease-nesting deadlock fix landed post-receipt

This receipt predates BK-106 (`bk106-sync-engine-fixes.md`, 2026-10-21 22:44),
which landed the lease-nesting deadlock repair (BK-83 finding 2): public
LEASE-WRAPPED `snapbackStoreOps()` → `setCursor` → public `markSynced` was a
nested same-client `navigator.locks` request that deadlocked under real Web
Locks; `applySnapback` now runs `snapbackWithStore(_snapbackStoreOps(), …)` and
`_snapbackStoreOps().setCursor` calls raw `_markSynced(seq)`. The standing line
above remains **ALIVE** post-fix: `node workspace/scripts/spof4-court.mjs`
re-run from `workspace/` on 2026-10-22 → 19 PASS / 0 FAIL, exit 0.
