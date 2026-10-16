# Receipt — V261014-08 (lane 08, servicebus census)

- **Subject**: working tree of /Users/sac/smalt on `main` @ 3fc2543 (uncommitted lane diffs; connection.ex carries lane 04's large in-flight diff plus my 8-line deliver_to_link edit — not separable in `git diff --stat`)
- **Date**: 2026-10-15
- **Status**: broker-side code + wire tests LANDED AND GREEN; census-probe additions WRITTEN-BUT-UNEXECUTED (no `SMALT_SDK_ROOT` in this lane environment; not faked)

## Tasks

### 08-1 lockDuration on delivery — CLOSED (code)
- `lib/smalt/messaging/amqp/connection.ex` `deliver_to_link/2`: resolves
  `QueueStore.queue_settings(link.address).lock_duration_ms` and passes
  `:lock_duration_ms` into `dequeue_matching/2` (8-line diff in lane 04's file).
  Store-side `dequeue_matching/2` already defaulted to the same value; the pass-through
  makes the delivery-claim path explicit. Clamp semantics untouched.
- Census budget hack rewritten (`test/sdk-smoke/census.test.cjs`): header comment
  retired; `stale-handle` probe now creates its queue with explicit `PT15S`
  lockDuration via `ServiceBusAdministrationClient` and waits 15 150 ms on that
  schedule (timeout 20 s); new `lock-duration` probe asserts a `PT2S` queue expires
  at ~2.15 s, which is impossible under the old 30 s effective default.

### 08-2 receive-by-sequence-number — CLOSED (code + wire tests)
- `management_rpc.ex`: `normalize_op/1` maps both bare-string and `{:symbol, _}`
  forms to `:receive_by_sequence_number`; handler resolves queue (body or request),
  accepts `{:array, _}` or list `sequence-numbers`, blank/malformed -> 400
  `SEQUENCE_NUMBERS_REQUIRED`; missing/non-deferred anywhere in the batch ->
  410 `MESSAGE_NOT_DEFERRED` (batch-atomic, chosen semantics documented in the
  handler comment + moduledoc status table); success 200 with the peek-message
  envelope (`messages[].message` + `sequence-number`).
- `queue_store.ex`: new `receive_deferred/3` (serialized `{:receive_deferred, ...}`
  call), two-pass batch validation then per-message re-lock via `LockManager.acquire`
  at the queue's configured duration; delivery_count incremented; atomic — no
  partial lock on failure. An interim lane-12 compile-freeze stub handler was
  replaced by this canonical handler (its `queue_from_request` undefined-variable
  bug would not compile).
- Wire tests: `test/amqp/management_rpc_test.exs` new describe block (4 tests):
  200 re-lock + complete path, 410 batch-atomic (asserts both deferred messages
  still `:deferred` after the failed batch), 400 blank/malformed, symbol-op +
  AMQP array-of-long form.

### 08-3 dead-letter-properties — CLOSED (code + wire tests)
- `management_rpc.ex` "suspended": reads `dead-letter-properties` map (default `{}`,
  non-map coerced to `{}`), passes `[properties: props]` to `QueueStore.deadletter/5`.
- `queue_store.ex` `do_deadletter/5`: merges `opts[:properties]` into the DLQ
  message's application properties after reason/description.
- DLQ-side delivery already surfaces `msg.app_props` via
  `DeliveryEncoder.build_sections` (app_props merge) — no encoder change needed;
  live-message baseline `build_properties` untouched.
- Wire tests: suspended-with-properties test asserts `CourtId`/`RetryCount` on the
  DLQ row; absent-props test pins unchanged behavior.

### 08-4 / 08-5 UNSUPPORTED tokens — DONE (docs)
- `docs/WIRE_PARITY.md`: new "Service Bus UNSUPPORTED (typed, V261014-08)" row
  (reply-to dropped-not-rejected + parked fix; subscription rules fail-closed);
  `$management` RPC row + status tables extended with receive-by-sequence-number.
- `docs/compliance/C5_SERVICEBUS.md` R11 updated with both tokens.
- `docs/compliance/C7_EVENT_PLANES.md` GAP list carries the SB typed-UNSUPPORTED entry.

### 08-6 findings.md drift — RECONCILED (option b)
- `test/redteam/r3_amqp/findings.md`: dated correction note added — on-disk
  `amqp_adversary.test.cjs` registers 42 `attack(...)` calls vs the claimed 46;
  46/43 figures flagged as as-run, pointer to `run.sh` re-run + cross-link to
  V261014-08. No attack bodies edited.

## Census probes (written-but-unexecuted)
`census.test.cjs` now registers 11 probes (was 8): added `dlq-properties`,
`lock-duration`, `deferred-receive`; `dead-letter` retained and the probe list
header updated. `node --check` passes. NOT executed: no `SMALT_SDK_ROOT` /
real `@azure/service-bus` available here. The census acceptance line
("11 probes green over the real SDK") is therefore OPEN, not claimed.

## Commands / exits
- `mix compile` — 0 errors in lane files (pre-existing unrelated warnings in
  arm_gateway/router.ex from other lanes remain).
- `mix test test/amqp/management_rpc_test.exs test/amqp/delivery_encoder_test.exs`
  — 42 tests, 0 failures.
- `mix test test/amqp` — **275 tests, 0 failures** (27 excluded), 7.1 s.
- `node --check test/sdk-smoke/census.test.cjs` — OK.

## Not done / falsifiers for the next lane
- Real-SDK census run (needs SMALT_SDK_ROOT + census-run.mjs substrate).
- `receiveDeferredMessages` reply shape over the wire (SDK envelope decode)
  — exercised only at the ManagementRpc contract tier here.
- findings.md 42-vs-46 re-run receipt.

## Cross-lane events
- Lane 04 owns connection.ex; my edit is the 8-line `deliver_to_link` block only.
- Lane 12's disclosed management_rpc.ex unblock stub was superseded (and its
  compile bug removed) by the canonical handler.
