# KD-85 witness: real @azure/service-bus reads a valid `enqueuedTimeUtc` end-to-end

- **KD**: KD-85 (Service Bus enqueued-time materialization)
- **Covers shim**: `lib/smalt/messaging/amqp/delivery_encoder.ex` (line 97 `# KD-COVERS: KD-85`), shim mtime 2026-10-20 18:57:28 PDT
- **Probe**: `verification/ts/kd85.probe.cjs` (boots its OWN private substrate block b11, ports 39110-39115, sweeps it down at exit — shared substrate untouched)
- **Date**: 2026-10-20 (run 21:25:32 PDT)
- **Standing**: ALIVE — PASS

## Method

Real SDK (workspace `@azure/service-bus`) against a real private smalt substrate
(`auth_mode: :enforce`, TLS certs, ARM health-checked on :arm_port). Sent one
message, received with `receiveAndDelete`, asserted:

1. `enqueuedTimeUtc` is a valid `Date` within 120s of the send time (send skew 37 ms)
2. The AMQP message annotations carry BOTH stamps (`x-opt-enqueued-time` + `x-opt-enqueued-time-utc`) — the dual-stamp shape emitted by the delivery_encoder shim

## Verbatim probe output

```
$ node verification/ts/kd85.probe.cjs
PASS enqueuedTimeUtc-real-Date
  enqueuedTimeUtc=2026-10-21T04:25:26.117Z (send skew 37ms)
PASS dual-stamp-annotations
  x-opt-enqueued-time=1792556726117 x-opt-enqueued-time-utc=1792556726117
SUMMARY pass=2 fail=0
EXIT=0
```

## Verdict

**KD-85 PASS.** The real SDK reads a valid `enqueuedTimeUtc` Date end-to-end
(37 ms send skew), with both annotation stamps surfaced on the wire. Receipt
postdates the shim (shim 2026-10-20 18:57:28 PDT, run 21:25:32 PDT).

## Notes

- First re-run attempt failed boot: `lib/smalt/application.ex` was mid-edit by
  another lane (MismatchedDelimiterError at 175:76, `if-do` fragment); the tree
  compiled clean on retry (MIX_ENV=test, MIX_BUILD_ROOT=_build-lane13, exit 0)
  and the probe then passed. No lib edits made by this lane.

## Register-row repair disclosure

This lane made one minimal mechanical fix outside its primary ownership:
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` KD-85 row — the close-condition cell
contained literal `|skew|` pipes that broke `kd_flip.py` `split_row` (status
parsed as `skew`, row invisible to flip logic). Escaped to `\|skew\|`; re-scan
then showed `KD-85: [OPEN]` and FLIP-ELIGIBLE with this receipt as witness.
No status flip applied (coordinator owns `--apply`).