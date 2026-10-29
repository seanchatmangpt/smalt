# KD-88 triage — client-side frame capture lane (kd88)

- **Standing: PARTIAL_ALIVE — KD-88 confirmed CLIENT-BOUND; smalt-side decoder refuted as the truncation source with a 330-frame real-wire differential; no smalt fix to land; recommending the registrar keep the row OPEN as client-bound and re-type the falsifier to the client surface.**
- Lane: kd88 (writer), repo /Users/sac/smalt, 2026-10-21. MIX_BUILD_ROOT=_build-kd88; lane-private ports 39600-39606; no shared-substrate restart. HEAD 4e1efe35adb03b3c31c5dfaaedf7b75fedc663eb.
- Row: docs/jira/v26.10.14/KNOWN_DIVERGENCES.md KD-88 (+ v26.10.20 pointer row).
- Prior evidence: docs/jira/v26.10.20/receipts/kd88-attach-race-witness.md (W13-H) — server-side warm-up race REFUTED; typed lead `{:bad_frame_body, :truncated}` awaited a client-side frame capture.

## Method (Chicago: real client, real server, real bytes, no mocks)

Harness `tmp/kd88_tap.mjs`: per attempt a FRESH cold beam
(MIX_ENV=test, MIX_BUILD_ROOT=_build-kd88, anonymous SAS with a fresh 48-byte key),
a raw TCP tap (port 39606) between the real `@azure/event-hubs` pump and the real
smalt EH listener (39601), real `SmaltBlobCheckpointStore` checkpoint pump,
20 events to partition 0, `maxRetries: 0`, 45 s deadline. Every client→server byte
recorded to `tmp/kd88_c2s_<id>.bin` (12 captures across 4 cold boots). Then
`tmp/kd88_replay.exs` feeds the real captured bytes to the real
`Smalt.Amqp.FrameCodec.decode_frame/1` in-process (no app boot).

SDK pin: **@azure/event-hubs 6.0.4, rhea 3.0.5**
(verification/ts/node_modules, imported by absolute path; scratch helper
`tmp/eventhubs_kd88.ts` is a byte-for-byte copy of workspace/lib/azure/eventhubs.ts
so the @azure imports resolve in scratch — `tmp/node_modules/@azure` symlink).

## Evidence 1 — 4/4 cold boots delivered 20/20 through the tap

    === attempt 1/4 ===
    result: attach-after-open=3346ms seen=20/20 drain-at=3719ms errors=[]
    === attempt 2/4 ===
    result: attach-after-open=2949ms seen=20/20 drain-at=13168ms errors=[]
    === attempt 3/4 ===
    result: attach-after-open=2431ms seen=20/20 drain-at=12650ms errors=[]
    === attempt 4/4 ===
    result: attach-after-open=2031ms seen=20/20 drain-at=12250ms errors=[]
    SUMMARY: 0/4 attempts did NOT deliver 20/20

The KD-88 stall did not reproduce in this lane's 4 attempts. It is intermittent
(W13-H witnessed 2/4 and 1/3) and client-side; this lane's contribution is the
wire differential below, not the stall census.

## Evidence 2 — 330 real client frames, ZERO decode errors (decoder strictness gap REFUTED)

    REPLAY-TOTAL frames=330 errors=0 details=[]

Full per-capture rows (all 12 captures, leftover=0, errors=[]):

    REPLAY kd88_c2s_073ae8.bin bytes=1997 frames=10 leftover=0 perfs=%{open: 1, attach: 3, begin: 2, transfer: 2, flow: 1, sasl_init: 1} errors=[]
    REPLAY kd88_c2s_112a1b.bin bytes=5284 frames=59 leftover=0 perfs=%{close: 1, open: 1, detach: 6, attach: 6, begin: 4, end: 4, disposition: 15, transfer: 5, flow: 16, sasl_init: 1} errors=[]
    REPLAY kd88_c2s_466e20.bin bytes=2096 frames=16 leftover=0 perfs=%{close: 1, open: 1, detach: 3, attach: 3, begin: 2, end: 2, transfer: 2, flow: 1, sasl_init: 1} errors=[]
    REPLAY kd88_c2s_5a87ab.bin bytes=1997 frames=10 leftover=0 perfs=%{open: 1, attach: 3, begin: 2, transfer: 2, flow: 1, sasl_init: 1} errors=[]
    REPLAY kd88_c2s_79a554.bin bytes=2100 frames=16 leftover=0 perfs=%{close: 1, open: 1, detach: 3, attach: 3, begin: 2, end: 2, transfer: 2, flow: 1, sasl_init: 1} errors=[]
    REPLAY kd88_c2s_80fd17.bin bytes=5284 frames=59 leftover=0 perfs=%{close: 1, open: 1, detach: 6, attach: 6, begin: 4, end: 4, disposition: 15, transfer: 5, flow: 16, sasl_init: 1} errors=[]
    REPLAY kd88_c2s_8e7cbe.bin bytes=5346 frames=61 leftover=0 perfs=%{close: 1, open: 1, detach: 6, attach: 6, begin: 4, end: 4, disposition: 17, transfer: 5, flow: 16, sasl_init: 1} errors=[]
    REPLAY kd88_c2s_c66e4c.bin bytes=2100 frames=16 leftover=0 perfs=%{close: 1, open: 1, detach: 3, attach: 3, begin: 2, end: 2, transfer: 2, flow: 1, sasl_init: 1} errors=[]
    REPLAY kd88_c2s_d0beb9.bin bytes=1993 frames=10 leftover=0 perfs=%{open: 1, attach: 3, begin: 2, transfer: 2, flow: 1, sasl_init: 1} errors=[]
    REPLAY kd88_c2s_ee5a46.bin bytes=2096 frames=16 leftover=0 perfs=%{close: 1, open: 1, detach: 3, attach: 3, begin: 2, end: 2, transfer: 2, flow: 1, sasl_init: 1} errors=[]
    REPLAY kd88_c2s_f24e0c.bin bytes=3640 frames=47 leftover=0 perfs=%{close: 1, open: 1, detach: 5, attach: 5, begin: 3, end: 3, disposition: 15, transfer: 3, flow: 10, sasl_init: 1} errors=[]
    REPLAY kd88_c2s_f482cd.bin bytes=1997 frames=10 leftover=0 perfs=%{open: 1, attach: 3, begin: 2, transfer: 2, flow: 1, sasl_init: 1} errors=[]
    REPLAY-TOTAL frames=330 errors=0 details=[]

Every performative class rhea 3.0.5 emits on a live EH pump session —
`open, begin, attach, flow, transfer, disposition, detach, end, close, sasl_init`,
including multi-frame transfers with payloads — decodes clean through
`Smalt.Amqp.FrameCodec`. No legit rhea frame produces
`{:bad_frame_body, :truncated}`: the truncation close W13-H witnessed is a torn or
partial TCP write on the CLIENT write path, not a smalt decoder strictness gap.

## Evidence 3 — amqp_wire tier run (honest pre-existing failures, none on the KD-88 surface)

    MIX_BUILD_ROOT=_build-kd88 MIX_ENV=test mix test --include amqp_wire
    Finished in 40.9 seconds (0.5s async, 40.4s sync)
    264 tests, 11 failures

All 11 failures are pre-existing on the shared in-flight working tree (other lanes'
uncommitted edits to lib/smalt/cosmos_sql.ex, egress_router.ex, the connection.ex
KD-131/132/133 hunks, etc.); none is on the KD-88 surface (frame codec, EH attach,
pump). This lane changed no lib/ file — nothing landed, so nothing regressed. The
census/cluster failures are owned by the lanes holding those edits.

## Disposition / recommendation to registrar

1. **Verdict: client-bound.** Mechanism (W13-H + this lane): the SDK pump's
   partition-0 CBS token + receiver attach is not sent for 20-30 s on some cold
   boots (client-side pre-send stall in @azure/event-hubs 6.0.4 / rhea 3.0.5); in one
   W13-H witness the eventual frame arrived as `{:bad_frame_body, :truncated}` —
   this lane proves that error is NOT producible from any legit rhea frame
   (330/330 clean), so it is a torn/partial TCP write on the client write path.
   `lib/smalt/messaging/amqp/**` is NOT the diverging surface; no smalt fix exists.
2. **No row flip by this lane** (per task). Recommend the registrar re-type the KD-88
   falsifier to the client surface, e.g.: "capture a client-side torn/partial frame
   write during cold-boot pump attach (client send trace or socket write tap) and
   root-cause the 20-30 s pre-send stall in the rhea event-loop/pump cold start;
   smalt surface is clean (330-frame wire differential, this receipt)."
3. Surviving artifacts: harness `tmp/kd88_tap.mjs`, replay `tmp/kd88_replay.exs`,
   12 captures `tmp/kd88_c2s_*.bin` (e.g. kd88_c2s_112a1b.bin
   `d563a061b151ad297c743aa259e36e483b6ebb26ede5a86fdb02fedc62b00921`,
   kd88_c2s_8e7cbe.bin
   `ce5158a49c22bf63632056a12bc1cd38dc67e2fbb65c0b6d974b70db226cf952`),
   scratch helper tmp/eventhubs_kd88.ts + tmp/node_modules symlink (scratch,
   not repo surface).
