# W13-R — EH selector-floor hardening witness (popcorn_demo live_eh.ex)

- **Lane**: W13-R (writer)
- **Files owned/changed**: `popcorn_demo/lib/popcorn_demo/live_eh.ex`,
  `popcorn_demo/test/live_eh_test.exs`,
  `docs/jira/v26.10.20/receipts/eh-selector-floor-witness.md` (this file)
- **Date**: 2026-10-20
- **Standing**: **ALIVE**

## Change (closes the W5-A diagnosis)

The EH roundtrip leg no longer replays the partition from seq 0:

1. The receiver attaches BEFORE the publish with the broker-native
   eventPosition `amqp.annotation.x-opt-offset > '@latest'`
   (`apache.org:selector-filter:string` described source filter, bare
   single-component value form). The broker resolves the floor to the
   partition's PRE-PUBLISH last-enqueued seq at attach time
   (`connection.ex` `eh_parse_event_position` "@latest" clause →
   `EventHubs.last_enqueued/1`).
2. Link credit is granted only AFTER the publish's `accepted` disposition
   (`credit_and_drain/2`), so the drain sees exactly the events enqueued after
   attach — O(new events), not O(backlog).
3. Flow frame shape byte-identical to the pre-hardening leg; sender attach,
   transfer and disposition shapes unchanged; `eh=OK/SKIP/FAIL` contract and
   `eh=OK(<hub>/<part>:<token>-roundtrip-<n>-events-scanned)` fragment
   unchanged.

## Wire findings (witnessed 2026-10-20, live broker :5673)

- **Selector described-form**: the filter must be a symbol-keyed described
  type with a BARE value (`0x00 0xA3 <len> "apache.org:selector-filter:string"
  0xA1 <len> <clause>`). The composite-list-wrapped form (list8 around the
  clause) detaches with `amqp:not-implemented` /
  `SELECTOR_UNSUPPORTED: <clause>` (attach echo first, then typed detach —
  KD-68 machinery working as designed).
- **DEFECT REGISTERED (out of lane ownership, for the coordinator)**:
  `$management` READ `com.microsoft:partition`
  (`lib/smalt/messaging/amqp/management_rpc.ex:971-1009`) looks up
  `:smalt_eh_partitions` with the bare partition id ("0") while the table is
  keyed `"ns/hub/partition"` (`event_hubs.ex:15`, `store_tables.ex:409`) — the
  RPC always reports `last_enqueued_sequence_number = 0`. Witnessed: the RPC
  returned 0 against a 30+-event partition; a `x-opt-sequence-number >= 'L+1'`
  selector built from that L replayed the whole backlog (39-41 events).
  Suggested owner: amqp/messaging lane. Not fixed in this lane (files outside
  W13-R ownership).

## Verification (real wire, live substrate pid 62236, never restarted)

Toolchain: Elixir 1.20.3-otp-28 (asdf shim path), MIX_BUILD_ROOT=_build-w13r.

```
$ cd /Users/sac/smalt/popcorn_demo && PATH="$HOME/.asdf/installs/elixir/1.20.3-otp-28/bin:$PATH" \
  MIX_BUILD_ROOT=_build-w13r mix run -e 'for _ <- 1..3, do: IO.inspect(PopcornDemo.LiveEh.run())'
{:ok, "eh=OK(popcorn-eh/0:w27-evt-1792557898870-roundtrip-1-events-scanned)"}
{:ok, "eh=OK(popcorn-eh/0:w27-evt-1792557898882-roundtrip-1-events-scanned)"}
{:ok, "eh=OK(popcorn-eh/0:w27-evt-1792557898885-roundtrip-1-events-scanned)"}
```

Backlog property (20 fillers seeded over the real wire via the new public
`publish_events/1`, then one run):

```
$ MIX_BUILD_ROOT=_build-w13r mix test test/live_eh_test.exs
...
Result: 5 passed   # 3 original + 2 new (backlog O(new-events) + repeatability)
```

Backlog test asserts the scanned count in the fragment == 1 exactly
(roundtrip scans ~1 event, not 20+); repeatability test asserts scanned == 1
across two consecutive runs after a 5-event seed. Full popcorn_demo suite:
`mix test` → **103 passed, 0 failures** (pre-existing baseline preserved).

## Honest notes

- During hardening, interim runs emitted extra events to partition "0"
  (failed iterations each published before failing); the partition backlog is
  ~45 events. Harmless: the floor makes all future runs O(new events).
- The `$management` RPC attempt (first implementation) is registered as a
  defect above, not silently dropped: its `last_enqueued_sequence_number`
  read is key-mismatched and would poison any client that trusts it.
- No git actions taken (lane contract: coordinator owns transitions).
