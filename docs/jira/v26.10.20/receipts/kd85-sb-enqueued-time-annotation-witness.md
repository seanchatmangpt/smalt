# KD-85 witness — x-opt-enqueued-time dual stamp (lane K7, 2026-10-21)

**Standing:** PARTIAL_ALIVE
Context: solo

Fix: lib/smalt/messaging/amqp/delivery_encoder.ex build_message_annotations/1
now stamps BOTH `x-opt-enqueued-time` (the annotation @azure/service-bus
materializes `enqueuedTimeUtc` from) and the legacy `x-opt-enqueued-time-utc`,
marked `# KD-COVERS: KD-85`. Additive; legacy readers unchanged.

Encoder witness (mix run --no-start, real DeliveryEncoder.build_sections/1):

    K7-85-ANN %{"x-opt-enqueued-time" => {:timestamp, 1792548000000},
                "x-opt-enqueued-time-utc" => {:timestamp, 1792548000000}}

Both keys present in the real outbound annotations map.

Full SDK falsifier (test 06, `enqueuedTimeUtc instanceof Date`) needs the
@azure/service-bus JS court; the previous subject (workspace/test/
servicebus_dataplane.test.ts) was deleted at 64f6099 and the V261019-08
successor has not landed, so the SDK-side witness is pending that successor.
A live-wire JS probe was attempted against the shared 5672 seat: rhea receiver
attach timed out (queue entity not provisioned on the live substrate — SB
entity provisioning is KD-51's face, a separate OPEN row). Standing is
PARTIAL_ALIVE until the SDK court replays the falsifier; FLIP-ELIGIBLE only
via that receipt.
## RE-WITNESS addendum (BK-REWIT2 lane, 2026-10-22)

Encoder probe re-run verbatim-class on the current tree
(MIX_BUILD_ROOT=_build-rewit2, mix run --no-start, exit=0):

```
K7-85-RE-WITNESS annotations: %{"com.microsoft:locked-until-utc" => 638355968000000000, "x-opt-enqueued-time" => {:timestamp, 1799254800000}, "x-opt-enqueued-time-utc" => {:timestamp, 1799254800000}, "x-opt-locked-until" => {:timestamp, 1700000000000}, "x-opt-sequence-number" => 42}
new key present: true
legacy key present: true
exit=0
```

`Smalt.Amqp.DeliveryEncoder.build_sections/1` stamps BOTH
`x-opt-enqueued-time` and `x-opt-enqueued-time-utc` (# KD-COVERS: KD-85 at
delivery_encoder.ex:97). SDK-side falsifier still gated on the V261019-08
successor court; standing unchanged: PARTIAL_ALIVE. exit=0
