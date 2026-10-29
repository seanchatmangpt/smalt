# KD-129 fresh post-shim witness (coordinator, 2026-10-21)

**Standing:** PASS
Context: solo

S19-A's receipt (23:01:28) predates its own final `connection.ex` edit
(23:01:52 — the `handle_amqp(:heartbeat, ...)` clause), so the mtime gate
correctly refused. This witness postdates both shim files:

```
$ MIX_BUILD_ROOT=_build-final mix run --no-start -e \
    'IO.puts(inspect(Smalt.Amqp.FrameCodec.decode_frame(<<0,0,0,8,2,0,0,0>>)))'
{:ok, %{type: :amqp, channel: 0, payload: "", performative: %{performative: :heartbeat}}}
```

The exact killing frame from S19-A's capture (`00 00 00 08 02 00 00 00` — the
empty-body heartbeat rhea sends at idle-timeout/2) now decodes to the typed
heartbeat performative instead of `{:bad_frame_body, :truncated}`. E2E
ALIVE-POST-HEARTBEAT + 94KB cold-boot capture replay: see
kd129-frame-capture-witness.md.
