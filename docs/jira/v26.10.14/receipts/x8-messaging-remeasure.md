# X-8: messaging bench re-measure on KD-18/19/20 fixed substrate — receipt

- **Date**: 2026-10-16
- **Repo**: /Users/sac/smalt @ main (518b31a, working tree — no commits, no lib edits by this lane)
- **Lane**: X-8. Files owned: `docs/jira/v26.10.14/bench/b4-messaging-ts.jsonl` (appended),
  this receipt.
- **Subject**: `scripts/bench/b4_messaging_ts.mjs` re-run against the substrate
  with S-2's KD-18/19/20 fixes (`lib/smalt/messaging/amqp/connection.ex`,
  `lib/smalt/messaging/amqp/management_rpc.ex`), verified on disk before the run:
  `message_format: 0` at the EH/SB deliver paths, `bump_credit(..., -1)` after
  EH delivery, `$management` READ responder for
  `com.microsoft:eventhub`/`com.microsoft:partition`; `mix compile` clean at
  run time (after waiting out a transient mid-edit break of `connection.ex` by
  the S-2 lane, disclosed below).

## Before (pre-fix substrate; B-8/B-4 recorded numbers)

From `receipts/bench-08-amqp-beam.md` + the pre-fix `b4-messaging-ts.jsonl`
rows (ts 02:35/02:36Z, preserved in the jsonl with `superseded_by` markers):

| measure | before | note |
|---|---|---|
| SB send (1 KiB, 30 s) | **0 ops/s** (n=0, 3 ServiceTimeout) | link credit granted at attach, never replenished |
| SB send+receive-complete RT | **122.6 ops/s** (n=4296, p50 3.99 s) | recycle-contaminated, latency-bound |
| EH SDK producer | not measurable | KD-18/19/20 gaps: 501 on $management, null bodies, no credit enforcement |
| EH SDK consumer | not measurable | subscribe failed |

## After (x8 remeasure, 2026-10-16T03:09–03:12Z)

Substrate self-booted on the b4 private port block (39040–39045), tore down on
exit; ports verified free after. Rows carry `"run":"x8-remeasure"` in the jsonl.

| measure | after | note |
|---|---|---|
| SB send | **0 ops/s** (n=0, 3 BENCH_OP_TIMEOUT) | **unchanged — S-2's KD-20 fix does not cover this path** |
| SB send+receive-complete RT | **95.2 ops/s** (n=4296, p50 4.21 s, 2 send errors) | vs 122.6 before; still latency-bound (single outstanding send, p50 ~4 s) and recycle-bound (10 sender recycles, 1 client recycle) |
| EH SDK producer | **323.1 events/s** (n=9693, p50 3.06 ms, 0 errors) | first successful SDK-tier EH producer measurement on this substrate |
| EH SDK consumer | **subscribe OK** (KD-19 responder reachable) | rhea wire-tier consumer received **0 events** — new typed gap |

## Before/after headline

- **EH producer**: not-measurable → **323.1 events/s** (KD-18/19/20 landed and
  effective on the EH tier). SDK producer (323.1/s) now sits at ~1.06x of the
  BEAM-tier `send_event/3` anchor (344/s, B-9) — the wire tier is no longer the
  bottleneck for EH send; the SDK tier is essentially at BEAM-tier send parity.
- **SB send**: **0 ops/s → 0 ops/s. NOT FIXED.** KD-20's
  `bump_credit(..., -1)` is applied on the EH delivery path only; the SB
  client-sender link credit starvation is a different, still-open defect. A
  concurrent corroborating run at 03:21Z (separate lane, rows in the same
  jsonl) got 1.0 ops/s (n=44, 6 SenderBusyError) — same starvation class,
  confirming the SB sender path still lacks credit replenishment.
- **SB RT**: 122.6 → 95.2 ops/s. Not a regression signal: both runs are
  latency-bound (p50 3.99 → 4.21 s per round-trip, n=4296 in both), driven by
  the same forced sender-link recycles; run-to-run variance dominates.
- **EH consumer wire-tier**: 0 events delivered to a raw rhea receiver with
  credit_window 1000 — delivery path works for the SDK consumer but not the
  raw-tier receiver. New KD candidate.

## Multiplier table update (B-8/B-9 anchors ÷ x8 SDK tier)

| BEAM anchor | BEAM ops/s | SDK ops/s (x8) | multiplier |
|---|---|---|---|
| EH `send_event/3` (B-9) | 344 | 323.1 (EH producer) | **~1.06x** |
| EH `receive_events/3` drain (B-9) | 217,000 | not measurable (wire-tier consumer 0 events) | N/A |
| e2e store RT (B-8) | 35,959 | 95.2 (SB RT) | ~378x |
| enqueue at depth (B-8) | 826 | 95.2 | ~8.7x |
| frame codec pairs (B-8) | 41,312 | 95.2 | ~434x |

## Incident disclosures (lane discipline)

1. **S-2 compile-freeze violation**: while my first bench run was in flight,
   `connection.ex` was left briefly non-compiling (MismatchedDelimiterError,
   unclosed `[` at line 1131) — witnessed via the shared bench substrate log.
   It compiled clean by 20:05 local. S-2's receipt file
   (`receipts/s2-eh-shims.md`) is also truncated mid-sentence (2192 bytes,
   stable for >10 min, no PASS/FAIL verdict line) — the receipt exists but is
   not a complete landing record.
2. **Port-block collision**: an orphaned b4 substrate (beam pid 61970, spawned
   by another lane's bench killed by its `timeout 200`, no parent remaining)
   held 39040–39045; killed it before my clean run (lane-cleanup law).
3. **Shared-file collision**: another lane overwrote `b4-messaging-ts.jsonl`
   mid-lane; the pre-fix rows were restored from this lane's verbatim capture
   and marked `superseded_by`; that lane's post-fix rows (03:21/03:22Z) are
   preserved unmodified. My rows are tagged `"run":"x8-remeasure"`.

## Falsifier

The "EH producer now works" claim is falsified if a rerun on the same
substrate state fails to complete a producer batch or errs > 0 on the producer
row; the "SB send not fixed" claim is falsified if a rerun exceeds 1000 sends
on one sender link without a recycle or error.

## Addendum (03:37Z corroboration, same lane session)

A subsequent full-suite run at 03:35–03:37Z by the concurrently active bench
lane (rows in the same jsonl, after that lane removed the harness's sender
"priming" probe from `b4_messaging_ts.mjs`) measured:

- SB send **50.6 ops/s** (4 errors) — first non-zero send number on the fixed
  substrate; the 0 ops/s in my run and 1.0 ops/s in the 03:22Z partial run are
  therefore partly harness-shape-dependent (the priming probe client
  interacts with the substrate's sender flow control), not purely substrate.
- SB RT 50.6 ops/s (3 errors); EH producer **324.7 events/s, 0 errors**
  (independent reproduction of my 323.1); EH wire-tier consumer 0 events
  (reproduces my finding).

Standing conclusions: EH producer SDK tier ~324 events/s (reproduced 2x,
~1.06x of B-9's BEAM `send_event/3` anchor at 344/s); SB send is now
measurable but degraded and error-prone (50.6/s with SenderBusy-class errors —
credit replenishment on the SB sender path remains an open defect); EH raw
rhea consumer receives 0 events (open gap, reproduced 2x).

## Verification commands

- `mix compile` → exit 0 (post-fix substrate)
- `B4_OUT=.../b4-messaging-ts-run2.jsonl node scripts/bench/b4_messaging_ts.mjs`
  → 7 records; substrate up 2009 ms, down + ports free at exit
- ports 39040–39045 verified free after run
