# KD-129 frame-capture witness — empty-body heartbeat frame misread as :truncated

- **Standing: ALIVE (fix landed, end-to-end witnessed). KD-129's row flip is coordinator-owned — no register edit by this lane.**
- Lane: S19-A (substrate-op + writer), repo /Users/sac/smalt, 2026-10-20.
- Files touched: lib/smalt/messaging/amqp/frame_codec.ex (surgical),
  lib/smalt/messaging/amqp/connection.ex (ONE dispatch clause — cross-lane
  minimal fix, disclosed here and in any connection.ex owner's receipt per
  the same-checkout fanout compile-freeze disclosure law), this receipt. No git ops.

## Root cause

The silent client deaths are the codec rejecting an EMPTY-BODY AMQP frame —
the transport heartbeat:

1. smalt's open reply always advertises a non-nil idle_time_out
   (connection.ex open handler; clamp floor 60s, ceiling 300s = @recv_timeout).
2. rhea (the engine under @azure/event-hubs + @azure/service-bus) arms
   heartbeat_out = setTimeout(this._write_frame, remote.open.idle_time_out/2)
   when the REMOTE open carries idle_time_out
   (verification/ts/node_modules/rhea/lib/connection.js:515/586);
   _write_frame() with no frame argument encodes an EMPTY frame
   (rhea transport.js logs it as "-> empty").
3. At idle/2 the real client sends 00 00 00 08 02 00 00 00 (size=8, doff=2,
   type=0, channel=0, no performative).
4. Pre-fix decode: body <<>> -> PrimitiveCodec.decode(<<>>) ->
   decode_value(<<>>) -> {:error, :truncated} -> frame_codec decode_body ->
   {:error, {:bad_frame_body, :truncated}} -> typed close. The heartbeat is
   fire-and-forget, so the client surfaces nothing — silent death, matching
   W13-H's signature (close ~20-30s into the pump-stall silence).

## Capture receipts

- Offline replay of a 94 743-byte c2s capture (8 cold boots, 989 frames: 28
  sasl_init / 28 open / 77 begin / 119 attach / 221 flow / 203 disposition /
  89 transfer / 119 detach / 28 close) through the real FrameCodec: every
  frame CLEAN ("VERDICT: CLEAN"); the heartbeat never fired in those windows
  because no session idled long enough.
- Truncation produced on demand: FrameCodec.decode_frame(<<0,0,0,8,2,0,0,0>>)
  pre-fix returned exactly {:error, {:bad_frame_body, :truncated}} on the
  running private beam (unit witness, not a reconstruction).
- Live heartbeat capture: real rhea client with idle_time_out 60s through a
  byte-dump proxy; the empty frame appears in the raw c2s bytes at offset 106
  (00 00 00 08 02 00 00 00), ~30s after open — the exact frame that pre-fix
  killed the connection, now decoded and consumed silently.

## Fix

frame_codec.ex decode_frame: an empty AMQP-layer frame body now decodes to a
typed transport heartbeat {:ok, %{type: :amqp, channel: ch, performative:
%{performative: :heartbeat}, payload: <<>>}} (AMQP spec 2.3.1: the frame body
may be empty). SASL-layer empty body keeps the pre-existing typed error. A
matching handle_amqp(:heartbeat, ...) no-op clause in connection.ex consumes
it (without it the not-implemented catch-all would still have closed the
connection). Both comments carry # KD-COVERS: KD-129.

## Verification ladder (all commands actually run, MIX_BUILD_ROOT=_build-s19a)

1. Unit: decode_frame(<<0,0,0,8,2,0,0,0>>)
   - pre-fix: {:error, {:bad_frame_body, :truncated}}
   - post-fix: {:ok, %{type: :amqp, channel: 0, performative: %{performative: :heartbeat}, payload: <<>>}}
   - SASL-layer empty body unchanged: {:error, {:bad_frame_body, :truncated}}
   - malformed performative still errors (sanity leg unchanged)
2. E2E: real rhea 3.0.5, real socket, byte-dump proxy; heartbeat frame at
   ~30s captured on the wire; session2 opens at 35s;
   OUTCOME: ALIVE-POST-HEARTBEAT; zero "closing on" lines in the beam log.
3. Wire gate: gates/amqp_invariant_driver.exs lockclamp leg (SASL+CBS+attach+
   transfer+delivery over the real wire) against the fixed beam -> GATE_JSON
   emitted.
4. Tiers: mix test test/integration -> 77 tests, 0 failures. Internal AMQP/EH
   tiers (eh_arm, event_hubs_consumer_groups, kd128, sb_topic_fanout) ->
   25 tests, 1 failure = kd115_credit_first_delivery, disposition below.
5. Cold-boot campaign through the proxy (W13-H-derived harness,
   /tmp/s19a_run.mjs): attempts 1-8 (pre-patch build) 8/8 delivered 20/20
   clean; attempts 9+ are DISCARDED session-introduced noise (this lane's own
   mid-campaign patch recompiled under the harness -> BOOT FAIL).

## kd115 failure disposition (pre-existing/concurrent, not session-introduced)

test/internal/kd115_credit_first_delivery_test.exs fails with the client
surfacing a link detach (condition: undefined) at negotiation time. Not this
fix: the probe run against my fixed beam produced ZERO server-side closes in
the beam log (no "closing on" lines) — the failure happens at SASL/link
negotiation before any empty frame could exist, and the kd115 probe/test files
are another lane's in-flight surfaces (dirty at session start; the test header
itself documents an in-flight w13j diagnosis lane).

## Cleanup state

Private beams and dump proxies (20672/20673) killed at end of run. Build root
_build-s19a left for coordinator lane-clean. All harness/proxy/replay scripts
are /tmp scratch (/tmp/s19a_*); repo writes are exactly frame_codec.ex,
connection.ex, and this receipt.
