# EXP1C — journal-sync / useSovereignTerminal repairs (W3, W4, W5, W8)

**Standing:** **ALIVE** — all four findings repaired, court green 13/13 x2, ws-lint 0 errors.
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main, lane EXP1-C)
Finds: docs/jira/v26.10.22/receipts/expl1-workspace-errc.md (W3/W4/W5/W8)

## Files

- `workspace/lib/engine/journal-sync.ts` (owned)
- `workspace/lib/engine/useSovereignTerminal.ts` (owned)
- `workspace/lib/engine/tab-lease.ts` — MINIMAL CROSS-SEAM EDIT, disclosed:
  the W5 abort-listener leak lives in `withWalLease` (not one of my two
  leased files). Change is additive-only (hold listener ref, remove on
  release); the W2-relocation lane had no in-flight edit to this file.
- `workspace/scripts/exp1c-journal-court.mjs` (new court)

## W3 — hardcoded clientId 0n

`ensureClientId()` (journal-sync): mints a random nonzero u64 once (crypto
when present, Math.random fallback), persists it in the `sync_cursor` store
under key `clientId`, reuses forever after. `useSovereignTerminal.admitAndCommit`
threads it through `appendLocal` — no more (0, seq) collision class.
Court legs: mint-once/persisted, distinct-after-wipe, append carries the
persisted identity into the wire segment.

## W4 — index-sliced receipt chain + swallowed deletion counts

- `Hydrated` gains `entries: {seqId, frame}[]`; `frames: Uint8Array[]` kept
  for the sync-e2e-court `verifyReceipt(ledger.value.frames, ...)` surface
  (read before write: that court is not in my lease).
- `_flushSync` slices by `entries` seqIds, never index, and a missing seqId
  anywhere in 1..lastSeq is a typed refusal
  (`SYNC_REFUSED "receipt chain gap: seqId N missing below acked horizon"`),
  not a wrong-chain verify. Falsifier ran exactly as dispatched: ledger
  {1,2,4}, lastSeq=3 -> `receipt chain gap: seqId 3 missing below acked horizon lastSeq=3`.
- `deleteSeqIds` get-then-delete over one transaction; returns the count of
  rows actually present. Witnessed through the real snapback path: seed
  {1,2,4}, cursor 1, server refusal head 0 -> purged=2, remaining=[1],
  cursor=0.
- `rehydratePlan` prefers real stored seqIds (`entries`) with the index
  fallback preserved for pre-entries callers (spof4-court leg4 stays green).

## W5 — openDb negative caching / onblocked / listener leak

- `dbPromise` resets on ANY open rejection (`.catch(() => { dbPromise = null })`),
  so a transient IDB failure no longer bricks the journal for the page
  lifetime. Witnessed: injected first-open failure -> first=STORE_FAILURE,
  retry=ok.
- `onblocked` -> typed `STORE_FAILURE` ("indexedDB open blocked (another tab
  holds an older version)") instead of a silently hung open promise.
  Witnessed: injected onblocked -> typed refusal, retry recovers.
- Found-and-fixed en route: `storeFailure` re-wrapped already-typed open
  errors, obliterating the detail (`[object Object]` witnessed in court run 2);
  typed JournalErrors now pass through with detail intact.
- tab-lease: `withWalLease` holds the external-signal abort listener ref and
  removes it on release. Witnessed via `events.getEventListeners`:
  before=0, after=0 across a full lease cycle.

## W8 — dead wrappers deleted

`markSynced` and `snapbackStoreOps` (zero callers; both re-request the
same-client Web Lock from inside a lease holder — nested-lock deadlock class)
are deleted, along with `leasedLoose` (used only by them). Zero code callers
confirmed by grep across workspace/{lib,scripts,app}; the only remaining
mention is a doc comment in useNetworkState.ts (not my file, untouched).

## Court

`node workspace/scripts/exp1c-journal-court.mjs` — exit 0, 13/13 PASS, ran
three times (deterministic). Conventions extend sync-e2e-court/codec-court
(byte-copied engine closure to OS temp scratch, `.ts` import rewrite, real
store state via the tracked shim `workspace/scripts/bk83/idb-shim.mjs` —
the W2-relocated location, no /tmp dependency; read-before-write confirmed
the other lane's relocation landed before my court was authored).

Embedded court output (run 3):

```
[PASS] w3.clientid-mint-once-persisted :: first=12534453182266284109 second=12534453182266284109
[PASS] w3.clientid-in-sync-cursor-store :: stored=12534453182266284109
[PASS] w3.fresh-world-mints-distinct-nonzero :: first=12534453182266284109 fresh=608219339869229851
[PASS] w3.append-carries-clientid :: segment.clientId=16339145735260076994 persisted=16339145735260076994
[PASS] w4.hydrate-entries-carry-seqids :: entries=[1]
[PASS] w4.gap-typed-refusal-not-wrong-chain-verify :: ok=false code=SYNC_REFUSED detail=receipt chain gap: seqId 3 missing below acked horizon lastSeq=3
[PASS] w4.deleteSeqIds-real-counts :: purged=2 remaining=[1] cursor=0
[PASS] w5.failed-open-retry-succeeds :: first=STORE_FAILURE retry=ok
[PASS] w5.onblocked-typed-refusal :: first=STORE_FAILURE detail=indexedDB open blocked (another tab holds an older version) retry=ok
[PASS] w5.wal-lease-abort-listener-removed :: ok=true listeners-before=0 listeners-after=0
[PASS] w8.dead-wrappers-deleted :: markSynced=undefined snapbackStoreOps=undefined
[PASS] w8.rehydratePlan-prefers-stored-seqids :: frames=1,2,4
[PASS] w8.rehydratePlan-index-fallback-intact :: frames=1,2
SUMMARY: 13/13 PASS, 0 FAIL
```

## Gates

- `just ws-lint` exit 0 (0 errors, 48 pre-existing warnings; journal-sync's
  `decodeFrame` unused-import warning is pre-existing, line 18 unchanged).
- Sibling node courts: codec PASS, snapback PASS, tab-lease PASS ("# FAIL: 0"),
  pattern 13/3/0 PASS, dom-contract PASS, receipt PASS, guard PASS.
  spof4-court exit 0 **from workspace/ cwd**; run from repo root it fails at
  tsc `--types node` resolution (pre-existing cwd sensitivity in that court's
  tsc invocation, unchanged by this lane — flagging for its owner).
- sync-e2e-court exit 2 — BLOCKED, session-external: boot compile fails in
  `lib/smalt/data_plane/kql.ex` (undefined `do_bin_value/2`, another lane's
  in-flight edit; compile-freeze SLA case). Not my surface; e2e re-run owed
  by whoever owns that repair once kql.ex compiles.

## Falsifiers

- W3: two engines, distinct persisted clientIds, same server -> both sync
  clean (court legs L1/L2 prove identity persistence + threading; the
  two-consoles-one-server leg rides the existing sync-e2e topology and is
  BLOCKED with it, disclosed above).
- W4 gap: seeded {1,2,4}, lastSeq=3 -> typed refusal (court L3, PASS).
- W5: failed open then retry -> recovers (L5/L6 PASS); abort listener count
  0 after release (L7 PASS).
- W8: wrappers gone, `J.markSynced === undefined` (L8 PASS).
