# r200e — KD-76 partition-key routing (repair lane 284)

Standing: ALIVE
Lane: 284 (MIX_BUILD_ROOT=_build-lane284)
Subject: lib/smalt/messaging/amqp/connection.ex, test/amqp/event_hubs_test.exs
Date: 2026-10-16

## KD-76

Partition-key-routed sends on a HUB-address sender link were stored under the
bare hub key (`eh_partition` of an address without `/partitions/`), so
partition-scoped receivers (`subscribe("0")`/`subscribe("1")`) never delivered
them — real Event Hubs routes a pk-stamped event to one partition (deterministic
hash of the key over the entity's partition set; smalt pins ["0","1"]) while the
x-opt-partition-key annotation still rides the event, and hub receivers see all
partitions.

## Change

`lib/smalt/messaging/amqp/connection.ex` (see git diff, lane 284, disclosed: this
file was also in-flight for other lanes — every lane-284 edit is KD-76-tagged
`# KD-COVERS: KD-76`):

- `eh_storage_partition/3`: on a pk-stamped transfer over a hub-address (no
  `/partitions/`) sender link, storage key becomes `"hub/partitions/N"` with
  `N = rem(md5(pk) first byte, 2)` over the pinned set ["0","1"]; partition-
  scoped or unkeyed sends keep the previous key.
- `deliver_eventhubs/2` dispatch: hub-address receiver links (no `/partitions/`)
  now aggregate the hub's partitions ["0","1"] plus the legacy bare-hub key
  (pre-KD-76 unkeyed hub sends stay visible), merged by enqueued-ms then seq,
  credit-bounded. Cursors are LINK-LOCAL per source partition
  (`eh_agg_cursors`), so a hub link does not inherit positions written by
  partition-scoped links (independent consumers, real-service semantics).
- `eh_pk_partition/1` deterministic md5-based hash; a pure function of the key.

`test/amqp/event_hubs_test.exs` — new describe "KD-76 partition-key routing":
1. wire test (real AMQP wire over TCP): pk event on hub-address sender ->
   exactly ONE partition receiver delivers (handle 1 or 2, not both), the
   hub-address receiver delivers it, and x-opt-partition-key round-trips
   (r200b non-regression) with x-opt-sequence-number intact.
2. unit test: pk hash is deterministic and distributes over the pinned set.

## Verification

    MIX_BUILD_ROOT=_build-lane284 mix test --include amqp_wire test/amqp/event_hubs_test.exs
    → 31 tests, 0 failures (no GenServer crash logs)

    MIX_BUILD_ROOT=_build-lane284 mix test --include amqp_wire test/amqp/
    → 363 tests, 0 failures

Full-dir first pass returned 2 failures (selector_epoch "unsupported selector"
+ broker_facade sweeper/listener supervision) that both pass in isolation and
passed on the re-run of the full dir — pre-existing timing flakes in the shared
tree, not session-introduced (receipted per same-checkout-fanout SLA).

## KD register

KD-76 row: left OPEN — close needs a real-SDK witness (probe receipt postdating
the shim mtime via kd_flip.py); no register flip performed by this lane.
