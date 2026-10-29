# BK-E2ER: sync-e2e-court re-run addendum (EXP1-C owed leg)

**Standing:** PASS
Context: solo
Date: 2026-10-22
Lane: BK-E2ER
Subject: re-run of `node workspace/scripts/sync-e2e-court.mjs` after the transient
compile freeze in `lib/smalt/data_plane/kql.ex` that blocked EXP1-C's original run
(exit 2, "substrate never up") recorded in
`docs/jira/v26.10.22/receipts/exp1c-journal-sync-repairs.md`.

## Result

The owed leg cleared. Both courts green:

- sync-e2e-court: **9/9 PASS, exit 0**
- exp1c-journal-court (regression witness): **13/13 PASS, exit 0**

## Court output — sync-e2e-court.mjs

```
$ node workspace/scripts/sync-e2e-court.mjs
BOOT_OK :: BK83_BOOT_OK enforce sync=:18543 sts=:18581
[PASS] auth.tokenless-401-challenge :: status=401 www-authenticate=Bearer authorization="http://127.0.0.1:9443/organizations", resource="http://127.0.0.1:18543", error="invalid_token", error_description="MissingBearerToken"
[PASS] auth.sts-mint :: expires_in=3600 jws-segments=3
[PASS] auth.tokenless-flushSync-refused :: ok=false code=SYNC_HTTP status=401
[PASS] sync.flush-5-200-verified :: ok=true lastSeq=5 verified=true bytes=320 leaves=5 markedTo=5
[PASS] sync.cursor-advanced :: cursor=5
[PASS] sync.corruption-typed-refusal :: code=SYNC_REFUSED_BY_SERVER detail=BAD_CRC32 serverHeadSeq=5 purged=2
[PASS] sync.snapback-purge-to-head :: cursor=5 unsynced=0 currentSeq=5
[PASS] sync.clean-resync :: ok=true lastSeq=6 bytes=320 p12-verified=true (cumulative ledger verify, KD-165 fix)
[PASS] sync.cumulative-receipt-vs-full-ledger :: verified=true leafCount=6 localFrames=6 root=e3ef069def056777
SUMMARY: 9/9 PASS, 0 FAIL
EXIT=0
```

## Court output — exp1c-journal-court.mjs (regression witness)

```
$ node workspace/scripts/exp1c-journal-court.mjs
[PASS] w3.clientid-mint-once-persisted :: first=10628600054876336925 second=10628600054876336925
[PASS] w3.clientid-in-sync-cursor-store :: stored=10628600054876336925
[PASS] w3.fresh-world-mints-distinct-nonzero :: first=10628600054876336925 fresh=11190501708400258730
[PASS] w3.append-carries-clientid :: segment.clientId=10013465398045840455 persisted=10013465398045840455
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
EXIT=0
```

## Environment notes

- No shared substrate was needed: the court boots its own private witness runtime
  (`workspace/scripts/bk83/boot.exs`, `MIX_BUILD_ROOT=_build-bk83`, ephemeral ports
  18543/18581). "quiesce after" satisfied trivially — no substrate was booted by this
  lane; no listeners remain on 18543/18581 post-run (verified with lsof).
- Transient port 9092 collision with another lane's live Kafka harness
  (`tmp/az1_boot_noapp.exs`, live LISTEN socket — not an orphan, left untouched)
  is irrelevant to this court's outcome; the shared substrate boot attempts made
  before reading the court harness both failed before listening and left no state.
- kql.ex compiles (the original blocker); no code changes made by this lane.

## Replay

```
cd /Users/sac/smalt
node workspace/scripts/sync-e2e-court.mjs   # exit 0
node workspace/scripts/exp1c-journal-court.mjs  # exit 0
```
