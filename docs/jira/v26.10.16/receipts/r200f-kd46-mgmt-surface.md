# r200f — KD-46 witness: SB $management surface (deferred redelivery deliveryCount)

Standing: PASS

## Subject

- KD-46 (v26.10.14 register, row 63): SB deferred redelivery — deferred message
  redelivered via receive-by-sequence-number carries no `deliveryCount`
  (undefined; probe asserts 2). Close condition: "set deliveryCount on deferred
  redelivery; falsifier: census.test.cjs:259 passes".
- Covering edit: `lib/smalt/messaging/amqp/connection.ex`
  (`maybe_delivery_count_section/1`, emits the AMQP header
  `delivery_count` from the management handler's `"delivery-count"` on the
  deferred-redelivery wire path). Token `# KD-COVERS: KD-46` added this session
  at that edit site (was landing natively without a token).

## Falsifier replay (KD-46's own terms)

Command:

```bash
SMALT_SDK_ROOT=/Users/sac/smalt/test/sdk-smoke/node_modules \
MIX_BUILD_ROOT=_build-lane290 \
SMALT_TEST_ARM_PORT=39790 SMALT_TEST_EGRESS_PORT=39791 \
SMALT_TEST_AMQP_PORT=39792 SMALT_TEST_EVENT_HUBS_PORT=39793 \
scripts/sb_census_replay.sh
```

(Private ports 39790-39793: 5672/9443 were held by the standing substrate, so
the census ran lane-private per docs/DEV_LOOP.md range 39000-39999. Two cold
`_build-lane290` runs exited 2 — the 60s substrate-up window expired during
first compile of ash/explorer/wasmex deps; third run on the warm root booted in
8030ms.)

Real output (third run):

```
[census-run] substrate up on 39792/39790 after 8030ms
▶ service bus census: 11 probes, fail-closed, zero skips
  ✔ probe: authentication (28.513458ms)
  ✔ probe: bytes (418.29275ms)
  ✔ probe: exclusive-session (50.873792ms)
  ✔ probe: renewal-peek (42.4445ms)
  ✔ probe: abandon-complete (9.557083ms)
  ✔ probe: stale-handle (15188.817875ms)
  ✔ probe: dead-letter (8.866333ms)
  ✔ probe: dlq-properties (14.495ms)
  ✔ probe: ordered-session (25.303375ms)
  ✔ probe: lock-duration (2166.242584ms)
  ✔ probe: deferred-receive (11.271584ms)
✔ service bus census: 11 probes, fail-closed, zero skips (17972.624541ms)
ℹ tests 12
ℹ suites 0
ℹ pass 12
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 18127.731584
```

Exit 0.

## Match to KD-46's close condition

The falsifier is `census.test.cjs:259` — `deferredReceiveCase` in
`test/sdk-smoke/census.test.cjs`, the `deferred-receive` probe above. Its
assertions (real run, all passed):

- `DEFERRED_RECEIVE_NONEMPTY`: receiveDeferredMessages returns exactly 1 message
- `DEFERRED_BODY_EXACT`: body deep-equals `[4,5,6]`
- `DEFERRED_DELIVERY_COUNT`: `deferred[0].deliveryCount === first.deliveryCount + 1`
  (i.e. 2 — the exact assertion KD-46 names as failing before the fix)
- `DEFERRED_GONE_AFTER_COMPLETE`: gone after complete

The `deliveryCount` is no longer undefined: the deferred redelivery carries
`first.deliveryCount + 1 = 2`, matching the probe. Close condition met on
KD-46's own terms, not merely "census green".

## Standing

PASS — witness receipt postdates the KD-46 covering edit's mtime; flip via
`scripts/kd_flip.py --apply`.
