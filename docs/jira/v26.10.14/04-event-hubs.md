# V261014-04 — Event Hubs wire delivery + session-lock consistency fixes

- **Release:** v26.10.14 · **Priority:** HIGH (fix 1 blocks all wire EH delivery)
- **Owned files:** `lib/smalt/messaging/amqp/connection.ex` (EH sections), `lib/smalt/messaging/event_hubs.ex`, `lib/smalt/messaging/amqp/lock_manager.ex`, `lib/smalt/messaging/amqp/queue_store.ex` (one handler), `test/amqp/event_hubs_test.exs`, `test/amqp/lock_manager_test.exs`, `test/compliance/c5_servicebus.exs`, `test/compliance/c7_events.exs`

## F1 — HIGH: EH receiver wire delivery is dead code

**Evidence (verified in tree):**

- `lib/smalt/messaging/event_hubs.ex:88-106` — `receive_events/3` returns a **bare list** (`@spec ... :: [map()]`).
- `lib/smalt/messaging/amqp/connection.ex:1077` — `deliver_eventhubs/2` matches `{:ok, events} when is_list(events) and events != []`. A bare list can never match `{:ok, events}`, so **every EH receiver link falls to `_ -> state` and no event is ever delivered over the wire**.
- Coverage gap: `test/compliance/c7_events.exs:207` calls `receive_events(partition)` directly (in-process), so the suite is green while the wire path is broken.

**Fix:** in `connection.ex` `deliver_eventhubs/2`, match the actual shape:

```elixir
case EventHubs.receive_events(partition, after_seq, link.credit) do
  [_ | _] = events -> ...   # non-empty bare list
  _ -> state
end
```

(Alternative — change `receive_events/3` to return `{:ok, events}` — rejected: breaks the public contract consumed by `c7_events.exs` and reconcile callers.)

**Required test (falsifier):** wire-level receiver test in `test/amqp/event_hubs_test.exs`: real AMQP receiver link on an `"/eventhubs/"` entity path, sender link sends events, receiver drain yields them in sequence order with the `x-opt-sequence-number` annotation. **Must fail against the current tree and pass after the fix** — that revert-failure is the proof-of-dead-code gate.

## F2 — MED: `LockManager.renew/3` leaves the session record stale

**Evidence:** `lock_manager.ex:115-118` — `renew/3` delegates to `renew_lock/3` (:272-281) which writes **only** `:smalt_sb_locks`. The mirrored `:smalt_sb_sessions` record (own `locked_until`) is never updated → stale-expiry spurious reclaim / double-acquire. `session_renew/4` (:249-262) does it correctly (renew_lock AND re-put into `:smalt_sb_sessions` when the record carries `:session_key`). Moduledoc (:242-244) promises "both records are kept in sync" for the token path — currently false.

**Fix (preferred):** `renew/3` looks up the token; if it is a session lock, delegate to `session_renew(queue, session_id, now_ms, opts)`; else mirror the session_renew body (`Store.put(:smalt_sb_sessions, {lock.queue, lock.session_id}, lock)` after `renew_lock/3`). Add `lock_manager_test.exs` cases: renew-by-token updates `:smalt_sb_sessions`; renew-by-token on a pure message lock creates no session rows.

## F3 — MED: `session_release/2` is not serialized (ST4 TOCTOU reopen)

**Evidence:** `lock_manager.ex:261-268` — direct non-serialized `Store.get` → `delete(:smalt_sb_locks, ...)` → `delete(:smalt_sb_sessions, ...)`. Concurrent `session_acquire/2` (serialized via QueueStore claim server, :165-167) can interleave between get and deletes: acquire wins on the not-yet-deleted record, then release deletes the fresh lock — lost-lock window, exactly the ST4 TOCTOU class the moduledoc (:160-161) claims closed.

**Fix:** serialize through the same server. Add a `{:session_release, queue, session_id}` `handle_call` in `queue_store.ex` (pattern: existing handlers at :426 `{:session_claim, ...}`, :433 `{:lock_sweep, now}`), move the get/delete body into it, route `session_release/2` through `GenServer.call(QueueStore.server(), ...)`.

**Required test (court):** deterministic 2-process racing release-vs-claim on the same `{queue, session_id}`; assert post-state is {lock held by B intact} or {lock released with B losing} — never a stale/held-by-A record or B's lock silently deleted. Use `now_ms` injection for determinism, no sleeps.

## F4 — LOW: moduledoc documents a `Store.compare_and_swap/4` delegation that does not exist

`event_hubs.ex:18-25` and `:110-115` claim CAS delegates to `Smalt.Store.compare_and_swap/4` when available; code always routes through `EHServer.transaction` (:139). Correct both doc blocks: CAS and sequence assignment are serialized through `EventHubs.Server`, race-free by construction. Docs-only.

## F5 — minor: reserve expiry asymmetry + discarded sender sequence

- `event_hubs.ex:156` computes expiry caller-side; the server's `:reserve` handler (~:366) reads its own clock. Normalize: pass `ttl_ms` (not absolute expiry) and compute `until` server-side — one clock source, documented.
- `connection.ex:619` binds and discards the assigned `seq`. Comment or debug-log only; do not change the return shape.

## Implementation order

1. F1 wire fix + wire-level receiver test (commit the test alone first — red-before/green-after).
2. F3 `{:session_release, ...}` handler + rerouting + race court.
3. F2 renew/3 sync + tests.
4. F4/F5 docs + clock normalization.
5. Full gate run.

## Acceptance criteria

- [ ] Wire-level EH receive test exists (real link, sequence order, `x-opt-sequence-number`).
- [ ] Falsifier demonstrated: reverting the :1077 fix turns the wire test red.
- [ ] `mix test test/amqp/event_hubs_test.exs test/amqp/lock_manager_test.exs` green.
- [ ] `c5_servicebus.exs` and `c7_events.exs` green.
- [ ] 2-process racing release/claim court passes deterministically (no sleeps).
- [ ] Renew-by-token keeps `:smalt_sb_locks` and `:smalt_sb_sessions` in sync (test-asserted).
- [ ] Moduledocs match implemented behavior.
