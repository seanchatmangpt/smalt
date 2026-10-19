# AZB-07 — Integration plane profile (Service Bus AMQP + Event Grid)

Standing: ALIVE

## Identity

- Ticket: `docs/jira/v26.10.18/azsim-burn/TICKETS.md` (AZB-07, binding)
- Subject: work tree at main, base HEAD `3d7e871` (AZB-04 loader landed in
  `be81187`); no git actions taken by this lane (coordinator owns commits)
- Files owned by this ticket:
  - `config/env/az_prod_integration.exs` (seeded by AZB-04, unchanged — port
    single-source flat key `:sb_endpoint`; `:amqp`/`:event_grid` carry no port key)
  - `lib/smalt/messaging/amqp/connection.ex` (config read sites + typed oversize
    close + broker-forced partition detach)
  - `lib/smalt/messaging/event_grid.ex` (NEW — Event Grid delivery engine)
  - `test/azsim/integration_plane_test.exs` (NEW — acceptance suite)

## What landed

### 1. `:amqp` profile read sites (one-source via `Smalt.Config.amqp/0`)

- `max_frame_size` (profile value 65536): clamped to the frame_codec hard cap;
  a frame whose DECLARED size exceeds the configured cap closes with the typed
  condition `amqp:frame-size-too-small`, connection close, never a crash.
  Unset (default boot) = hard-cap-only — default behavior byte-identical
  (existing `test/amqp/connection_test.exs` oversize expectations unchanged:
  125 tests, 0 failures in regression, see Verification).
- `sasl_mechanisms` (profile value `[:anonymous]`): the wire pinion is
  VERBATIM — exactly `ANONYMOUS` is advertised
  (`server_mechanisms == [{:symbol, "ANONYMOUS"}]` asserted in test). A
  configured list EXCLUDING :anonymous refuses the ANONYMOUS sasl_init with
  sasl_outcome code 1 + typed close `amqp:unauthorized-access`.
- Broker-forced partition detach (real EH service behavior): new
  `Smalt.Amqp.Connection.force_partition_detach/2` detaches the receiver
  link(s) on a partition address with `amqp:link:detach-forced`
  (PARTITION_DETACH), keeping the connection up so the client relink is
  clean. Pump-blocking note: the detach message is processed on the next
  inbound frame (single-process recv pump); the test wakes the pump with a
  credit grant, mirroring real relink flows.

### 2. `lib/smalt/messaging/event_grid.ex` (new)

At-least-once fan-out keyed by topic; subscription survives subscriber crash
(un-acked inflight event REQUEUED on recovery, same `id`); publish dedup on
`id` per topic (`:fresh`/`:duplicate`); publish-while-down queues the event
(never loss). `delivery_mode` read site: only `:at_least_once` (or unset) is
admitted; any other value typed-refused with ArgumentError naming the mode —
a lossy mode is deliberately NOT implemented; the anti-vacuity shim witnesses
why (below). Zero `Process.sleep` (resubscribe-driven + bounded
`Process.send_after` backoff). Lazy-start (QueueStore pattern) — NO
application.ex child; `:plane` unset = today's child list preserved
(application.ex untouched by this lane; the in-flight AZB-09 lane owns it).

## Acceptance (real output)

`mix test test/azsim/integration_plane_test.exs` — 9 tests, 0 failures:

```
9 tests, 0 failures
```

Round-trip covers send/receive/complete + abandon-requeue +
deadletter-after-max-delivery-count (ARM record pins maxDeliveryCount=2,
`DeadLetterReason: MaxDeliveryCountExceeded`), oversize frame typed close
(`{:frame_exceeds_configured_max, 4096, 2048}` -> `amqp:frame-size-too-small`,
socket closed, conn stopped), profile-excluding-:anonymous typed refusal,
partition detach-forced + clean relink (post-relink event delivered on the
relinked receiver), Event Grid dedup (`:fresh`/`:duplicate`), crash =>
redelivery same id, publish-while-down => delivered after recovery.

## Falsifier (witnessed)

"An Event Grid event published and never delivered after subscriber recovery":
the "event published while down is delivered after recovery" test drives
exactly this scenario (subscribe -> kill subscriber -> bounded-poll DOWN ->
publish -> recovery subscribe) and asserts delivery — published events are
NEVER lost across recovery, so the falsifying observation is excluded by a
real execution, not prose.

## Anti-vacuity (witnessed, SHIM-COURT)

Shim (marked SHIM-COURT): recovery drops the un-acked inflight event
(ack-before-dispatch loss class) in `lib/smalt/messaging/event_grid.ex`.

```
BASELINE sha256=aa4b12b6d78605e1bb83b465c437774f1974ce542ac5f31cfbb1635e1da53e2f
== BEFORE  -> 1 test, 0 failures (green)
== SHIM    -> SHIM-COURT marker applied
== AFTER   -> test RED: assert_receive {:got2, ^topic, "crash-1"} — the loss
              test FAILS under the shim (the flip IS the non-vacuity proof)
== RESTORE -> sha256 aa4b12b6d78605e1bb83b465c437774f1974ce542ac5f31cfbb1635e1da53e2f
              RESTORE-OK byte-exact (fail-closed)
POST-RESTORE -> 1 test, 0 failures (green)
```

Additionally the config-mode refusal test (delivery_mode :at_most_once) is
typed-refused at publish — the lossy mode cannot be configured into the engine.

## Regression (pre-existing suites)

```
mix test connection_test event_hubs_test queue_store_test frame_codec_test broker_facade_test
125 tests, 0 failures (23 excluded)
```

## Ontology / smalt.gen

No new config keys (AZB-04 seeded ck-amqp / ck-event-grid / ck-sb-endpoint in
the smalt-substrate-pack ontology; `Smalt.Config.amqp/0`, `event_grid/0`,
`sb_endpoint/0` accessors are the one-source read surface). `mix smalt.gen`
replay exit 0 with zero drift on generated files (`lib/smalt/config.ex`
untouched; `test/config_replay_identity_test.exs` green in the combined run:
19 tests, 0 failures).

## Constraints honored

- `:plane` unset = today's child list: application.ex untouched by this lane;
  EventGrid lazy-starts (no child added).
- Existing config keys one-source: all reads via `Smalt.Config.*` accessors
  (ontology census); no new keys, no port keys in plane profiles.
- test.exs untouched: zero edits to existing test files (one compile-freeze
  unblock DISCLOSED: `test/support/lifecycle.ex` — another lane's in-flight
  @doc contained an unescaped `#{prefix}` interpolation breaking all-lane
  compile; minimal fix escaped it to `\#{prefix}`. Both lanes' receipts
  should name this).
- Zero `Process.sleep` in new code (grep clean; bounded-poll helper used).
- Pinions verbatim: SASL ANONYMOUS-only advertised set, EH fixed partitions
  ["0","1"] (unmodified), sasl-outcome descriptor 0x44 path untouched.

## Standing derivation

ALIVE: acceptance suite green on the real wire (raw :gen_tcp AMQP client),
real store, real EventGrid engine; falsifier + anti-vacuity witnessed with
byte-exact restore; regression 125/0.
