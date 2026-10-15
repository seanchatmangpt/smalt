# AMQP Fan-out Stress Receipt

Driver: `scripts/stress/amqp_fanout.exs` (pure Elixir, no network listeners).

    mix run --no-start scripts/stress/amqp_fanout.exs

## Subjects

- `Smalt.Amqp.QueueStore.dequeue_matching/2` / `complete/2` / `enqueue/3`
  (`lib/smalt/messaging/amqp/queue_store.ex`)
- `Smalt.Amqp.LockManager.session_acquire/3`
  (`lib/smalt/messaging/amqp/lock_manager.ex`)
- `Smalt.Store` ETS tables (`lib/smalt/store.ex`)

## Scenario

- **Phase A** — 200 concurrent receivers (credit 1 each: at most 1 in-flight
  message) + 20 senders, 50 msgs each (1000 total), one queue
  `stress.fanout`. Hot-loop receivers with a 1 ms breather every 16 polls.
- **Phase B** — 200 concurrent session receivers race
  `LockManager.session_acquire/3` on one session (`s1`) of queue
  `stress.session`; winner dequeues with a session filter.

## Results (4 real runs, OTP 28 / Elixir 1.19.5, darwin)

Phase A across runs (1000 messages enqueued every time):

| metric | run 1 | run 2 | run 3 | run 4 |
|---|---|---|---|---|
| messages settled (delivery events) | 82,329 | 99,070 | 80,573 | 59,291 |
| residual in queue after drain | 0 | 0 | 0 | 0 |
| active receivers | 200/200 | 200/200 | 200/200 | 200/200 |
| per-receiver min/max | 365/625 | 447/661 | 351/553 | 242/650 |
| fairness max/min ratio | 1.712 | 1.479 | 1.575 | 2.686 |
| spurious `:empty` | 53 | 126 | 160 | 98 |
| rescued `MatchError` in `messages/1` | 25,578 | 25,899 | 25,659 | 25,370 |
| orphaned lock tokens at end | 4,398 | 6,508 | 4,887 | 3,504 |
| fanout wall time | 5.4 s | 5.9 s | 4.4 s | 3.2 s |

*Note on "settled" counts*: 59–99k delivery events for 1000 enqueued messages
is not throughput — it is **duplicate delivery**: `dequeue_matching/2` is a
non-atomic scan→acquire→put pipeline, so under 200 racers many racers deliver
the same seq before any settles it. Delivery throughput is therefore
meaningful only as ~18-31k deliveries/s of *events*; the useful (unique
message) throughput is 1000 / ~5 s ≈ **200 msg/s** bounded by this race.

## Findings

1. **CONFIRMED — `dequeue_matching/2` is not race-safe (pre-existing).**
   `queue_store.ex:249-286` + `messages/1` (`:421-435`):
   - read race: `:ets.match` lists a seq, a concurrent `complete/2` deletes it
     before `Store.get` → `{:ok, val}` match crash in the racer
     (`queue_store.ex:432`) — **25k crashes per 5 s run**, rescued+counted by
     the driver (200 receivers would each die on first hit otherwise);
   - duplicate delivery: two racers both scan the same available seq, both
     `LockManager.acquire` (which overwrites unconditionally —
     `lock_manager.ex:57-73`), both `Store.put` the message back as `:locked`
     → one `complete` deletes, the other's `put` **resurrects** it → 59-99k
     delivery events for 1000 messages;
   - orphaned locks: only the completer's token is released; every other
     racer's token for the same seq stays in `:smalt_sb_locks` forever
     (4-6k leaked tokens per 1000-message run; a 4000-message run leaked
     enough to OOM the VM at 219k deliveries).
   Falsifier: rerun the driver — duplication factor ~60-100x on every run.
   Fix shape (not applied — outside owned files): atomic claim via a single
   `:ets.update_element` on state/lock fields with the old state in the guard,
   or move dequeue into a single-owner process (GenServer claim) or
   `:ets.select_replace`-style CAS.

2. **CONFIRMED — `session_acquire/3` TOCTOU.** get-check-put
   (`lock_manager.ex:124-135`) is non-atomic: run 1 of phase B admitted **2
   winners / 198 already_locked**, runs 2-3 admitted 1/199. At 200 racers the
   window is real; verdict B intermittently FAIL. Falsifier: rerun — winner
   count > 1 is the observable.

3. **Fairness of the fan-out itself is healthy** where contention allows:
   all 200 receivers served, per-receiver max/min ratio 1.5-2.7 across runs
   (dup-delivery inflation makes every receiver "busy", so the ratio
   understates contention unfairness), zero idle receivers, zero residual
   messages after drain. The unfairness signal (`spurious :empty`) is rare
   (53-160 vs ~25k read races).

## Verdicts

- **Phase A: FAIL (correctness), PASS (drain + fairness mechanics).**
  Full drain, 200/200 receivers served, per-receiver max/min 1.5-2.7 — but
  60-100x duplicate delivery, ~25k caller crashes per run inside
  `QueueStore`, and unbounded lock-token leak make `dequeue_matching/2`
  unsafe at this concurrency.
- **Phase B: INTERMITTENT FAIL** — 1 winner on 2 of 3 runs, 2 winners on one
  run. Exclusive session is not guaranteed under concurrent
  `session_acquire/3`.

## Disclosure (session-introduced, outside owned files)

One minimal compile-unblock during the run window: escaped a bare
`#{container}` in the `list_blobs` docstring of
`lib/smalt/data_plane/blob_storage.ex` (`\#{account}/\#{container}/`) —
another lane's in-flight edit had broken the shared compile. No other
non-owned-file edits. (A second transient break, `egress_router.ex` syntax
error, was another lane's mid-edit state; recovered on its own within the
compile-freeze SLA window without my intervention.)

## Reproduce

    mix run --no-start scripts/stress/amqp_fanout.exs

Runs in ~5 s; prints both phase reports + verdict lines.
