# i29 wrap items — G1 register flip + s10 verify

- **Standing: PASS**
- **Context: solo(canonical checkout /Users/sac/smalt, no git actions)**
- Date: 2026-10-19

## Item 1 — G1 flip (receipt-gated)

Gate: `docs/jira/v26.10.18/receipts/i29-g1-land.md` exists on disk (verified:
`ls` — file present, Standing: ALIVE, evidence: lib/smalt/data_plane/queue_storage.ex,
egress_router `queue_storage_plane` plug arm, 2 StoreTable rows; engine 11/0 +
wire 26/0 + regression 482/0 embedded in the receipt).

Flips in `docs/jira/v26.10.18/azsim-burn/SOVEREIGN_MIDNIGHT.md`:

- Coverage row line 26: Queue Storage **MISSING → COVERED** with
  receipts/i29-g1-land.md pointer.
- Gap register line 37: **G1. MISSING → G1. COVERED** with surface summary +
  receipt pointer.

Verified by grep after edit (actual output):

```
26:| 4 Data | **Queue Storage (popreceipt, visibility, stale-replay)** | **COVERED** | queue_storage.ex engine + egress_router plug arm (queue_storage_plane, before blob splat) + 2 StoreTable rows; engine 11/0 + wire 26/0 + regression 482/0 (receipts/i29-g1-land.md) |
37:G1. COVERED — Queue Storage data plane landed (queue_storage.ex + egress_router queue_storage_plane arm + 2 StoreTable rows); engine 11/0 + wire 26/0 + regression 482/0 — receipts/i29-g1-land.md
```

## Item 2 — i29-e2e-fixes landed; s10 verify-only

`docs/jira/v26.10.18/receipts/i29-e2e-fixes.md` is on disk (Standing: ALIVE)
and documents the s10 exit-contract fix (trap disarm + `set +e` + watchdog
kill by captured pid). Fix confirmed in the working tree —
`test/e2e/s10_attest_adversary/run.sh` carries `trap - EXIT INT TERM` /
`set +e` in cleanup (lines 66-67) and `kill "$WATCHDOG_PID" 2>/dev/null || true`
(line 97). No re-application needed.

Fresh s10 run this session (actual output):

```
$ bash test/e2e/s10_attest_adversary/run.sh
EXIT=0
[PASS] court.summary: 10 pass / 0 known-gap / 0 fail
CONTROL-OK: attest refused with substrate down (port 38443): URLError
[s10] adversary suite exit: 0 ; control exit: 0
[s10] COURT PASS
```

Log: /tmp/s10-wrap-run.log. Receipt:
test/e2e/s10_attest_adversary/.logs/receipt.json.

## Verification ladder

- [x] i29-g1-land.md exists on disk (flip gate)
- [x] SOVEREIGN_MIDNIGHT.md coverage row + G1 register flipped, grep-confirmed
- [x] i29-e2e-fixes.md landed; s10 trap fix present in run.sh
- [x] s10 run exit 0 ×1 with COURT PASS + CONTROL-OK
