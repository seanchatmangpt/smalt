# BK-131 sync-e2e court re-run on current HEAD

**Standing:** ALIVE

Context: full

Subject: smalt @ d7fa05ef966974f81313da6e8260bd9aed08c2dc (branch main).
Re-run of BK-83/BK-106's authenticated sync end-to-end court
(`workspace/scripts/sync-e2e-court.mjs`) on current HEAD, since the last run
predated BK-106 auth wiring and the BK-115b absolute-path fix.

## Method

- 3 consecutive runs of `node scripts/sync-e2e-court.mjs` from `workspace/`
  cwd, asdf-pinned toolchain (elixir 1.20.4-otp-29 / erlang 29.1.2 injected
  by the script itself), enforce-mode runtime spawned on ephemeral ports
  sync=:18543 sts=:18581 (`MIX_BUILD_ROOT=_build-bk83`).
- Plus 1 run each of `receipt-court.mjs`, `snapback-court.mjs`,
  `codec-court.mjs` from the same cwd.

## 3x run record (sync-e2e-court)

| run | boot | result | exit |
|---|---|---|---|
| 1 | BK83_BOOT_OK enforce sync=:18543 sts=:18581 | 9/9 PASS, 0 FAIL | 0 |
| 2 | BK83_BOOT_OK enforce sync=:18543 sts=:18581 | 9/9 PASS, 0 FAIL | 0 |
| 3 | BK83_BOOT_OK enforce sync=:18543 sts=:18581 | 9/9 PASS, 0 FAIL | 0 |

All three boots clean, no port-wait fallback needed (BK-92-F1 guard silent).

## Per-leg status (identical PASS set in all 3 runs)

| leg | status | evidence |
|---|---|---|
| auth.tokenless-401-challenge | PASS | 401 + `WWW-Authenticate: Bearer authorization="http://127.0.0.1:9443/organizations"`, error=invalid_token MissingBearerToken |
| auth.sts-mint | PASS | expires_in=3600, 3-segment JWS |
| auth.tokenless-flushSync-refused | PASS | ok=false code=SYNC_HTTP status=401 |
| sync.flush-5-200-verified | PASS | ok=true lastSeq=5 verified=true bytes=320 leaves=5 markedTo=5 |
| sync.cursor-advanced | PASS | cursor=5 |
| sync.corruption-typed-refusal | PASS | SYNC_REFUSED_BY_SERVER / BAD_CRC32, serverHeadSeq=5, purged=2 |
| sync.snapback-purge-to-head | PASS | cursor=5 unsynced=0 currentSeq=5 |
| sync.clean-resync | PASS | lastSeq=6 bytes=320 p12-verified=true (cumulative ledger verify, KD-165 fix) |
| sync.cumulative-receipt-vs-full-ledger | PASS | verified=true leafCount=6 localFrames=6; roots 3f7aa91258609ce3 / 4c32a99b872f9970 / b348f61f4eda6384 (per-run, as expected) |

## Companion courts (1x each, exact exits re-captured without pipe)

| court | verdict | exit |
|---|---|---|
| receipt-court | all assertions passed | 0 |
| snapback-court | all assertions passed | 0 |
| codec-court | verdict: PASS (0 failures) | 0 |

## Classification

No failures observed. BK-106 auth wiring (401 challenge -> STS mint ->
bearer flushSync) and BK-115b absolute-path handling both behave correctly
on current HEAD; no court-script or lib repairs needed this lane.

## Replay

```
cd /Users/sac/smalt/workspace
node scripts/sync-e2e-court.mjs   # x3, exit 0 each
node scripts/receipt-court.mjs    # exit 0
node scripts/snapback-court.mjs   # exit 0
node scripts/codec-court.mjs      # exit 0
```

Not committed (per lane instruction).
