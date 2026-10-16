# Receipt — V261014-04 (Event Hubs wire delivery + session-lock consistency)

Lane 04 of the v26.10.14 20-lane fan-out. Canonical checkout `/Users/sac/smalt`, branch `main` (no commits made, working-tree diff only).

## Changes

- **F1 (HIGH)** `lib/smalt/messaging/amqp/connection.ex` `deliver_eventhubs/2` — matched `receive_events/3`'s actual bare-list return (`[_ | _] = events`) instead of the impossible `{:ok, events}`; also fixed the cursor update and body/annotation reads that still used atom-key access (`ev.seq`/`ev.body`) on string-keyed event maps (both would have raised on first delivery). Falsifier comment in place.
- **F1 test** `test/amqp/event_hubs_test.exs` — wire-level receiver court: real `:gen_tcp` AMQP client, SASL ANONYMOUS + open/begin handshake, sender link on `/eventhubs/<hub>/partitions/0` (3 transfers, accepted dispositions), receiver link + flow credit, drain yields 3 transfers in sequence order, each with integer `x-opt-sequence-number` message annotation; payload byte-integrity asserted. Tagged `:amqp_wire` (default-excluded per `test/test_helper.exs`; run with `--only amqp_wire`). Self-contained harness (no CBS needed — `route/2` gates auth only for `:queue` kind).
- **F2** `lib/smalt/messaging/amqp/lock_manager.ex` — `renew/3` on a session token now delegates to `session_renew/4`; plus the underlying defect: `session_renew/4`'s mirror write was guarded by `Map.has_key?(lock, :session_key)`, a key only ever present on the `:smalt_sb_locks` token row, never on the `:smalt_sb_sessions` row it read — guard never fired, mirror stayed stale. Guard removed, sessions row always re-put (comment documents why). Tests: renew-by-token updates both tables; renew-by-token on a message lock creates no session rows.
- **F3** `queue_store.ex` — one new `handle_call({:session_release, queue, session_id}, ...)` clause appended directly after `{:session_claim, ...}` (no restructuring; lane 08's sections untouched). `LockManager.session_release/2` routes through `GenServer.call(QueueStore.server(), ...)`; body moved to `LockManager.do_session_release/2` (runs inside the server). Race court: 50 phases, 2 concurrent processes release-vs-claim with injected `now_ms`, no sleeps; asserts only the two lawful linearizations (B intact + A token gone, or B already_locked + clean release).
- **F4** `event_hubs.ex` moduledocs — removed the false `Smalt.Store.compare_and_swap/4` delegation claims; both doc blocks now state CAS/sequence assignment are serialized through `EventHubs.Server`, race-free by construction.
- **F5** `event_hubs.ex` — `reserve_processing/4` passes relative `ttl_ms`; the `{:reserve, ...}` server handler computes `until = now + ttl_ms` from its own clock. connection.ex:619 sender path already bound the discarded seq with a fail-closed comment (pre-existing, satisfies the F5 comment-only requirement; no return-shape change).

## Falsifier witness (red-before / green-after)

- **Red-before**: with the exact pre-fix match shape (`{:ok, events} when is_list(events) and events != []`) restored in `deliver_eventhubs/2`, the wire test failed — sender ingest succeeded (3 accepted dispositions received, attach echo received), receiver credit granted, then **timeout waiting for any transfer**: no event was ever delivered. (Trace witnessed via temporary frame logging: `:attach` → `:flow` → `:disposition` ×3 → receiver `:attach` → silence.)
- **Green-after**: `mix test test/amqp/event_hubs_test.exs --only amqp_wire` → `1 test, 0 failures (37 excluded)`.
- Both states witnessed on this checkout in this session; the debug instrumentation was removed before the green run.

## Gates (actual output)

| Gate | Command | Result |
|---|---|---|
| Acceptance files | `mix test test/amqp/event_hubs_test.exs test/amqp/lock_manager_test.exs` | `37 tests, 0 failures (1 excluded)` |
| Wire tier | same + `--only amqp_wire` | `1 test, 0 failures (37 excluded)` |
| Compliance | `mix test test/compliance/c5_servicebus.exs test/compliance/c7_events.exs` | `17 tests, 0 failures (16 excluded)` |
| Compliance wire | same + `--only amqp_wire` | `16 tests, 0 failures (16 excluded)` |
| Determinism | lock_manager suite ×3 | 0 failures each |

## Cross-lane coordination

- `queue_store.ex`: single appended clause per the lane contract; lane 08's `management_rpc.ex` / `census.test.cjs` untouched.
- Shared-compile breaks from other lanes (`egress_router.ex`, `cosmos.ex`, `blob_service.ex`) hit during the run; waited out per the compile-freeze SLA, none owned by lane 04.
- No git state changes, no commits.

## Notes / residuals

- The wire test asserts event-body byte preservation (stored EH body is the raw encoded section the sender transferred, constructor prefix included) — pinned as-is, that is the ingest storage contract, not a defect.
- `LockManagerTest` setup creates `:smalt_sb_locks`/`:smalt_sb_sessions` directly (caller-side table create) — pre-existing pattern outside this lane's scope.
