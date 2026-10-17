# Court-x2 wrap runs 29–30 — RED (shifting-failure, terminal)

- Standing: **RED — gate FAIL, no two-green** (run 30 `COURT_X2_RC=1`; run 29 no verdict)
- Lane: Terminal FINAL updater, 2026-10-17 (runs 01:46–02:17)
- Subject: `tmp/court-x2-wrap-run29.log` (run 29), `tmp/court-mock-free.log` not used; `tmp/court-x2-wrap-run30.log` (run 30, terminal witness)
- No fixes applied (docs-only lane).

## Run 29 — INCOMPLETE, no verdict

Run 29.1 failed (3 failures), run 29.2 started 01:49 and the log went
stale (no COURT_X2_RC line, no court process running at 02:21). No
verdict was produced; superseded by run 30.

## Run 30 — terminal RED witness (real log output, tmp/court-x2-wrap-run30.log)

Both runs exit 2 on `test-offline`, each `1 doctest, 7 properties, 2435 tests, 1 failure`:

    [COURT-X2] Failing tests — run 1:
    test readback merges CloudEvents and EG1 events of one topic by seq (Smalt.EventGridTopicsArmTest) (test/eventgrid_topics_arm_test.exs:302)
    [COURT-X2] Failing tests — run 2:
    test receive_deferred duplicate sequence numbers (R160b) [seq, seq] yields exactly one lock and one envelope (Smalt.Amqp.QueueStoreTest) (test/amqp/queue_store_test.exs:721)

## Signature

Shifting-failure / FLAKE_SOLO signature fired:

    [COURT-X2] *** SHIFTING-FAILURE / FLAKE SIGNATURE DETECTED ***
    [COURT-X2] Run 1 and run 2 failed on DIFFERENT tests. This is the
    [COURT-X2] flake class this session spent a wave killing. Investigate.

## Typed class

**FLAKE_SOLO residual, court-environment load class** — same family as
r216 (run 12) and r224 (`FLAKE_SOLO` classification,
`r224-framecodec-diagnosis.md` §Classification: "load/parallelism
artifact, court-environment"). Not a deterministic regression: run 30.1
and 30.2 fail on different tests (EventGrid readback-merge /
QueueStore deferred-dup-seq), neither reproducible within the gate.
Note: the dispatched task named the residual as "Metadata-indexer load
FLAKE_SOLO"; the run-29/30 witnesses do NOT name a Metadata-indexer
test — the terminal witnesses name EventGridTopicsArmTest and
QueueStoreTest as this round's shifting failures, so the residual
family is recorded by its actual members.

## Verdict

RED terminal for this window: no two-green. Standing stays
**PARTIAL_ALIVE**. Rerun court-x2 on a quiet tree next window before
any two-green receipt.
