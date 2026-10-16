# S-2: KD-18/19/20 EH shims — receipt

Lane: S-2 (v26.10.15 wave), repo /Users/sac/smalt, branch main, no commits.
Subject SHAs (final, post-court): `connection.ex` 0446c9bf…, `management_rpc.ex`
414c9e14… (sha256, verified byte-identical after every court restore).

## What landed

1. **KD-19** — `connection.ex` `$management` request map forwards
   `type`/`name`/`partition` application properties;
   `management_rpc.ex` `normalize_op/2` is (operation, type)-keyed: `READ` +
   `com.microsoft:eventhub` → 200 hub payload
   `{name, created_at (AMQP timestamp), partition_ids ["0","1"],
   georeplication_factor 1}`; `READ` + `com.microsoft:partition` → 200
   `{name, partition, begin_sequence_number 1, last_enqueued_sequence_number
   (non-destructive read of the `:smalt_eh_partitions` row `"seq"`),
   last_enqueued_time_utc, last_enqueued_offset, is_partition_empty}`;
   unknown partition → typed `404 PARTITION_NOT_FOUND`. Moduledoc op table
   updated.

   **Design deviation, disclosed**: the E-3b design cited
   `EventHubs.next_sequence/1` as the sequence source; `next_sequence/1`
   BUMPS the counter, so a mgmt poll would burn sequence numbers and mint
   rows for unknown partitions. The read goes to the partition row directly.
   Fixed partition set `["0","1"]` (probe hub topology).
2. **KD-18** — `deliver_eventhubs/2` transfer carries `message_format: 0`
   (SB-path pattern; the format!=0 raw passthrough left SDK-tier bodies
   null/Buffer) and re-emits the decoded body section via `eh_body_section/1`:
   a raw byte scan for the body-data section header
   (0x00 0x53 0x75 + vbin8/vbin32), **recursive** — the SDK producer stores
   the BATCH ENVELOPE message whose body_data wraps ANOTHER encoded message
   stream, so one unwrap level leaves the SDK tier holding described-section
   bytes (independently witnessed by the F-4 fin27-batch-send receipt).
   Tolerant scanner because `FrameCodec.decode_message/1` is all-or-nothing.
   Fallback closed: no body section → whole payload.
3. **KD-20** — `bump_credit(state, link.channel, link.handle, -1)` after each
   EH delivery (SB-path pattern).

KD-COVERS tokens: `KD-19`, `KD-18,KD-20`, `KD-18` at the three edit sites
(S-1 carries KD-21/KD-49 in disjoint hunks; both sets present at court time).

## Mutation court — scripts/shim_court/eh_mgmt_court.sh — VERDICT: NON-VACUOUS

Phases (final run 2026-10-16 ~03:30 UTC):
- Baseline sha256 recorded; restore sha256-verified (`sha256sum -c` OK both
  files, every run).
- **BEFORE** (KD-19 fields + KD-18/20 delivery hunks textually stripped):
  getEventHubProperties → GAP-CLASS `501 UNSUPPORTED_OPERATION`;
  getPartitionProperties → 501 both partitions; wire delivery bodies null
  (ORDER_VIOLATION, format!=0 raw passthrough). Exactly the registered gaps.
- **AFTER** (hunks present): hub/partition READ 200 (partitionIds ["0","1"];
  begin=1 end=0 offset=0), unknown partition → 404 PARTITION_NOT_FOUND,
  wire delivery ordered-sequence PASS (6/6, seq [1..6]).
- Known-drift gate: `wire-delivery-raw-payload-decode` fails in AFTER with
  its own output proving the flip ("total deliveries seen: 10, undecodable:
  0" — the SDK tier now decodes the message; the probe asserts the obsolete
  format!=0 Buffer passthrough). Accepted with note; probe rewrite queued
  (X-10/integration candidate), not a substrate gap.

## Retest receipts (all 2026-10-16)

- `mix test test/amqp/event_hubs_test.exs test/compliance/c7_events.exs
  test/wire/amqp_wire_test.exs` → **37 tests, 0 failures** (1 excluded) —
  green before AND after the court.
- `node test/sdk-full/eventhubs.probe.mjs` → 4/5 PASS (residual fail =
  raw-payload premise drift above).
- `SMALT_SDK_ROOT=$PWD/test/sdk-full node test/sdk-smoke/eh-run.mjs` →
  **4/4 PASS** — get-properties ✔, batch-send ✔ (F-4's exact-string deepEqual
  now passes via the recursive envelope unwrap — the brief expected this to
  stay red as test-code drift; it flipped green), subscribe-earliest ✔
  (214 ms), suite exit 0.
- `ManagementRpc` unit: READ/eventhub → 200 hub payload; READ/partition →
  200 partition payload; unknown partition → 404 PARTITION_NOT_FOUND
  (MIX_ENV=test mix run).

## Env receipts

- Elixir 1.19.5 / OTP 28.3.1, MIX_ENV=test; probe substrate ports 39690-39694
  (private block).
- Court + probe runs went through a hostile shared tree: sibling lanes broke
  compile 3x (bearer.ex, application.ex, virtual_serial.ex/frame.ex) and
  restored stale connection.ex baselines over this lane's hunks ~6 times;
  all landings re-verified by sha256 before/after each run. No lane clobbers
  remain (final shas stable through probe + court).
- `test/sdk-full/node_modules` (live @azure/event-hubs + rhea) — Chicago-style
  real collaborators throughout; no mocks.

## Notes for integration

- KD-19's `["0","1"]` partition set is a shim constant (probe topology); a
  real hub-registry would derive partition_ids from the store (X-10).
- The `wire-delivery-raw-payload-decode` probe (and the batch-send note in
  the wave brief) are now premise-drift: format 0 + recursive unwrap makes
  their assertions obsolete. Probe rewrite queued, not a substrate gap.
- KD-19's READ is non-mutating by design (no `next_sequence/1` bump); a
  later design wanting next-seq semantics can expose a separate op.
