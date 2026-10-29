# r8 — T-08: Service Bus native DLQ, scheduled messages, message deferral

- window: v26.10.28 · ticket: `tickets/T08-servicebus-dlq-scheduled-deferral.md` · date: 2026-10-29
- tier: beam (`test/integration/sb_delivery_test.exs`) · status: **CODE-COMPLETE (2026-10-29): r8, awaiting integration run**

## landed

1. **New engine module `lib/smalt/messaging/sb_delivery.ex`**
   (`Smalt.Messaging.SbDelivery`) — the store-backed SB delivery control
   surface, owning:
   - `dlq_name/1` / `subscription_dlq_name/2` (scope 1): every queue's
     subqueue is `"<queue>/$deadletterqueue"`, every subscription's is
     `"<topic>/Subscriptions/<sub>/$deadletterqueue"` — real AMQP-receivable
     entities (receiver links attach to the subqueue address; the connection
     lane already normalizes the SDK's `$DeadLetterQueue` casing on attach,
     `connection.ex` DLQ-suffix handling).
   - Message record extensions (scope 2/3): `scheduled_enqueue_at/1`,
     `deferred?/1` (the deferral flag), `sequence_number/1` (surfaces on
     every received row; a DLQ copy carries its own fresh per-DLQ sequence).
   - `dead_letter/5` (the ticket's `dead_letter/4`): two forms — a stored
     `(entity, seq, reason, description[, opts])` settlement move (token-
     scoped CAS through `QueueStore.deadletter/5`), and a not-yet-stored
     `msg_map` form (the rule fan-out no-match face: fresh DLQ copy via
     `QueueStore.enqueue/3`). Both stamp `DeadLetterReason` /
     `DeadLetterErrorDescription` into the DLQ copy's application properties
     (SDK parity: `serviceBusMessage.js` reads them from application
     properties) AND annotations, and carry body / message-id / session-id /
     original application properties / delivery count over intact.
   - `schedule_cancel/2` (scope 2): cancel by sequence number; only
     still-`:scheduled` rows cancel, typed `:not_scheduled` / `:not_found`
     refusals.
   - `receive_deferred/3` (scope 3): sequence-only receive; the batch fails
     atomically with `{:error, {:not_deferred, refused}}`; qualifying rows
     re-lock at the queue's configured duration (abandon/lock-expiry return
     the row to `:deferred`, never to the available rotation).
   - `visible?/2`: the receive-visibility gate — `:deferred` and `:dead`
     rows never; `:scheduled` rows only at/after `scheduled_enqueue_time`.
   - Time discipline mirrors the EventHubs injected-clock pattern: every
     time-dependent call forwards `opts[:now_ms]` / takes `now_ms` — courts
     are zero-sleep.
2. **`lib/smalt/sb_rules.ex` — the "never DLQ here" line is gone**: the
   filter-no-match delivery decision in `fan_out/4` is config-keyed.
   Default (`config :smalt, :sb_dlq_on_filter_no_match` unset/false) keeps
   the real-Azure face — the no-match copy is skipped, not dead-lettered.
   Opt-in `true` dead-letters the no-match copy into
   `"<topic>/Subscriptions/<sub>/$deadletterqueue"` with
   `DeadLetterReason: "NoFilterMatch"` and original application properties
   intact. `subscription_admits?/2` itself stays a pure predicate (its
   docstring now describes the config-keyed caller decision); everything
   else in the module untouched.
3. **`lib/smalt/messaging/amqp_broker.ex` — surgical facade wiring**: a
   comment block mapping each wire behavior to its seam, plus four
   delegates exposing the surface on the broker:
   `sb_visible?/2` (→ `SbDelivery.visible?/2`), `dead_letter/3-4`,
   `schedule_cancel/2`, `receive_deferred/2-3`. No supervisor children
   changed (`SbDelivery` is stateless; the QueueStore claim/settle server
   remains lazily started).

## wiring patch status — none required

The scope's "receive paths exclude scheduled-future and deferred messages;
a dead-letter settle routes to the DLQ subqueue" is already live on the
AMQP wire and needed NO patch (the receive path lives in
`lib/smalt/messaging/amqp/connection.ex`, T-12's file, untouched):

- `Smalt.Amqp.Connection.deliver_to_link/2` → `QueueStore.dequeue_matching/2`
  → `claim_candidates/3` rejects `:deferred`, `:dead`, still-locked, and
  `:scheduled`-future rows (`scheduled_enqueue_time > now`) — exactly
  `SbDelivery.visible?/2`.
- `Smalt.Amqp.Connection.settle(:deadletter, ...)` (rejected outcome, and
  the max-delivery paths in `QueueStore.do_release`/`do_sweep`) →
  `QueueStore.deadletter/5` → `do_enqueue_locked` on
  `<entity>/$deadletterqueue` with reason/description from the rejected
  outcome's error info (`DeadLetterReason` /
  `com.microsoft:dead-letter-reason` accepted spellings).
- Scheduled send rides `QueueStore.enqueue/3`'s `:scheduled_enqueue_time`
  opt (fed from send annotations and the REST route's
  `ScheduledEnqueueTimeUtc`); cancel + receive-by-sequence ride the
  `$management` RPC (`com.microsoft:cancel-scheduled-message`,
  `com.microsoft:receive-by-sequence-number` → `QueueStore.receive_deferred/3`).
- `SbRules.fan_out/4` currently has no live wire caller (QueueStore's own
  fan-out via `Smalt.Amqp.RuleStore` gates the wire path); the no-match DLQ
  therefore lands in the sb_rules engine where its scope names it, and the
  same config key governs both engines' no-match faces should they be
  unified.

## StoreTables note

**None.** `SbDelivery` invents no tables — it reuses `:smalt_sb_queues`,
`:smalt_sb_messages`, `:smalt_sb_locks` (all registered in
`Smalt.StoreTables.table_names/0`), mutated only through the serialized
`Smalt.Amqp.QueueStore` claim/settle server. No registry change, no
regeneration.

## court

`Smalt.Integration.SbDeliveryTest` (`test/integration/sb_delivery_test.exs`;
real Store ensemble, real QueueStore GenServer, real `SbRules.fan_out/4` —
no mocks; zero sleeps, every visibility fence via injected
`now_ms`/`:scheduled_enqueue_time`) — 6 tests:

1. **DLQ round-trip (queue)**: receive → dead-letter (token-scoped) →
   `peek`/receive on `t08q/$deadletterqueue`: body, message id, ORIGINAL
   application properties intact, `DeadLetterReason`/`DeadLetterErrorDescription`
   on app-props + annotations, fresh DLQ sequence surfaced, source queue
   empty (moved, not copied), and the subqueue claims through the normal
   receive path (AMQP-receivable) and completes.
2. **DLQ round-trip (subscription)**:
   `subscription_dlq_name("t","s") == "t/Subscriptions/s/$deadletterqueue"`
   and the stored-path move lands there with reason + original props intact.
3. **Scheduled timing fence**: enqueued with
   `scheduled_enqueue_time: due` — row surfaces `scheduled_enqueue_at`,
   `visible?` false at `due - 1` / true at `due`; `dequeue_matching`
   `:empty` before, deliverable exactly on time with sequence surfaced.
4. **Schedule cancel**: `schedule_cancel/2` → `:ok` before firing; the
   message never appears at/after the timestamp; typed refusals for a live
   (`:not_scheduled`) and absent (`:not_found`) sequence.
5. **Deferral round-trip**: defer settlement → deferral flag on the row,
   `visible?` false, normal receive `:empty`; `receive_deferred/3` on a
   wrong sequence → atomic `{:error, {:not_deferred, _}}`; on the right
   sequence re-locks and re-delivers by sequence number; complete spends it
   (second receive → `:not_deferred`).
6. **No-match default + config-keyed DLQ**: default (env unset) — fan-out
   returns `[]`, DLQ empty, matching subscription still admits; env `true` —
   fan-out returns `[]` but the DLQ carries the copy (`NoFilterMatch`
   reason, `color=blue` original property intact); env restored in
   `on_exit`.

**Not yet executed** — the r8 lane is code-only per the compile-freeze SLA
(no mix/test/git in this pass); the court runs with the next integration
pass and this receipt + the ticket stamp say so.

## DoD mapping (@azure/service-bus developer flow)

- "`receiver.deadLetterMessage(msg, {deadLetterReason: 'poison'})` moves the
  message; the ops receiver on `myqueue/$deadletterqueue` (or the
  subscription DLQ) receives it with the reason and original application
  properties intact" → court tests 1–2 (settle is token-scoped; the wire
  face is the existing `settle(:deadletter, ...)` seam documented in the
  broker facade).
- "`sendScheduledMessages([{body}], Date.now()+60_000)` — receivers see
  nothing for a minute, then receive exactly on time" → court test 3, with
  the minute elided by injected timestamps (poll-observable, zero-sleep).
- "`cancelScheduledMessage` kills one before it fires" → court test 4.
- "defer a message and pull it later with `receiveDeferredMessages([seq])`
  using the sequence number you logged at receive time" → court test 5
  (`sequence_number/1` is what the receiver logs; `ReceiveSequenceNumber`
  rides the existing `x-opt-sequence-number` delivery annotation from
  `DeliveryEncoder.build_sections`).
- "filter-no-match optionally dead-letters (config key, default: no-match
  does NOT dead-letter)" → court test 6 + `config :smalt,
  :sb_dlq_on_filter_no_match`.

Non-goal respected: no forwarding rules between DLQs (T-16, deliberately
sequenced after this lands).
