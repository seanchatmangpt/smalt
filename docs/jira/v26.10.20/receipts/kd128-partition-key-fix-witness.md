# KD-128 partition readout key-mismatch — fix + real-wire witness

- **Date**: 2026-10-20
- **Lane**: S13-F (writer)
- **Repo**: /Users/sac/smalt (canonical checkout)
- **Subject**: `lib/smalt/messaging/amqp/management_rpc.ex` (surgical,
  `eh_partition_row`), new seam test
  `test/internal/kd128_partition_readout_test.exs`
- **Standing**: PASS (fix landed at HEAD 6df2902; BEFORE/ AFTER wire-witnessed;
  seam tests green)
- **Context**: solo
- **Authority**: lane task S13-F; files owned per _LANES.md partition

## Defect

The `$management` READ `com.microsoft:partition` handler looked up
`:smalt_eh_partitions` with the bare partition id (`"0"`) while the table is
keyed by the composite `"<hub>/partitions/<p>"` (KD-68: partition identity is
hub-scoped). The lookup always missed, so every partition readout reported
`last_enqueued_sequence_number = 0` against a partition with real traffic
(W13-R witnessed: RPC said 0 against a 30+-event partition; a selector
`>= 'L+1'` built from it degenerated to a full replay).

## Fix

`eh_partition_row/2(hub, partition)` now matches the real key the store side
writes (`connection.ex eh_storage_partition/3`: `"<hub>/partitions/<p>"`):
exact match on the trimmed key, then `"<hub>/partitions/<p>"` suffix match
(shortest key wins when several namespace spellings exist) — the same
discipline as `Smalt.ARM.EhArm.partition_metrics/2` (KD-68 precedent). The
hub comes from the request's `name` application property (`eh_entity/1`).
`# KD-COVERS: KD-128` marker carried in the source.

## Witness (Chicago school — real wire, real store, no mocks)

Private beam (fixed code, `MIX_BUILD_ROOT=_build-s13f`) on private ports;
client is a minimal gen_tcp AMQP 1.0 client over the real wire using
`Smalt.Amqp.FrameCodec`. Script: `tmp/kd128_witness.exs`.

Commands and exits:

```
MIX_BUILD_ROOT=_build-s13f mix compile                  # exit 0 (1 pre-existing warning, Smalt.DataPlane.Cosmos.effective_ttl, unrelated)
MIX_BUILD_ROOT=_build-s13f mix run --no-start tmp/kd128_witness.exs   # exit 0
MIX_BUILD_ROOT=_build-s13f mix test test/internal/kd128_partition_readout_test.exs  # 2 tests, 0 failures
```

Private-beam boot log (real listeners, no port collision with the live
substrate, which was never restarted):

```
Running Smalt.EgressRouter ... at 127.0.0.1:38443 (http)
Running Smalt.ArmGateway.Router ... at 127.0.0.1:39443 (http)
...TlsTwinDispatch ... 39444 (https)
[amqp] sb listener bound on port 36672
[amqp] eh listener bound on port 36673
Running Smalt.Mcp.Router ... 39545 (http)
```

**AFTER (fixed code), 3 events published over the wire to
kd128-hub/partitions/0, all accepted:**

```
published event 1: accepted
published event 2: accepted
published event 3: accepted
=== $management com.microsoft:partition response (AFTER fix) ===
status_code: 200
status_description: "OK"
body: %{"begin_sequence_number" => 1, "is_partition_empty" => false,
  "last_enqueued_offset" => "3", "last_enqueued_sequence_number" => 3,
  "last_enqueued_time_utc" => {:timestamp, 1792559268810}, "name" => "kd128-hub",
  "partition" => "0", "statusCode" => 200, "statusDescription" => "OK"}
last_enqueued_sequence_number: 3
KD128-WITNESS: PASS
```

**BEFORE (shim court — old bare-`"0"` lookup re-inserted, marked
`SHIM-COURT`, same 3 accepted publishes, same request):**

```
published event 1: accepted
published event 2: accepted
published event 3: accepted
body: %{"begin_sequence_number" => 1, "is_partition_empty" => true,
  "last_enqueued_offset" => "0", "last_enqueued_sequence_number" => 0,
  "last_enqueued_time_utc" => {:timestamp, 0}, ...}
last_enqueued_sequence_number: 0
KD128-WITNESS: FAIL   (expected: the witness exits 1 on the shim)
```

Restore verified fail-closed: `sha256` of the restored file equals the fixed
snapshot (`2ab6312aaecddd67688345bbb20fb2acde9bafa3617b5af09a6fe8c3a334d729`).

## Seam test

`test/internal/kd128_partition_readout_test.exs` — drives the public
`Smalt.Amqp.ManagementRpc.handle/2` seam against the real
`Smalt.Messaging.EventHubs` store (real store writes via
`EventHubs.send_event/3` on the composite key; no mocks):

```
MIX_BUILD_ROOT=_build-s13f mix test test/internal/kd128_partition_readout_test.exs
..
Finished in 0.04 seconds (0.00s async, 0.04s sync)
2 tests, 0 failures
```

## Replay

```
MIX_BUILD_ROOT=_build-s13f mix run --no-start tmp/kd128_witness.exs
MIX_BUILD_ROOT=_build-s13f mix test test/internal/kd128_partition_readout_test.exs
```

## Notes / falsifiers

- The live shared substrate (beam 37113 on 5672/5673) was NOT restarted; the
  witness rode a private beam on private ports. The running substrate's
  in-memory EH partitions are unaffected; popcorn legs against the live
  substrate pick the fix up on its next supervised restart.
- The BEFORE shim run and the AFTER run each booted a fresh private beam and
  a fresh store, so the 0-vs-3 delta is attributable to the lookup alone.
- Falsifier that would break this receipt: publish >= 3 events to
  `<hub>/partitions/0` over the wire and observe
  `last_enqueued_sequence_number < 3` (or 0) from the `$management` READ
  `com.microsoft:partition` response.
