# SCVD-T8 — Backpressure Audit Receipt (lib/smalt)

Date: 2026-10-21. Scope: Task.async_stream / max_concurrency, GenServer call
timeouts, pools, timeout handling on the load (data-plane) paths.

## Key structural facts

- `Task.async_stream` / `max_concurrency`: ZERO hits under lib/smalt — the
  substrate does no fan-out batching; concurrency is process-per-connection
  (AMQP listener -> DynamicSupervisor, `restart: :temporary`, no connection cap).
- No poolboy / NimblePool / pool library anywhere in lib — no pooling layer.

## Load-path classification

| Load path | Site (file:line) | Bounding mechanism | Class |
|---|---|---|---|
| EventGrid per-subscriber event queue | lib/smalt/messaging/event_grid.ex:330 (`queue: :queue.new()`), enqueue at :446/:470 | TTL drop-at-dispatch only (default 86_400s, event_grid.ex:399-421); NO maxlen, enqueues for DOWN subscribers | **UNBOUNDED — HIGH** |
| EventGrid topic dedup set | lib/smalt/messaging/event_grid.ex:186-189 (`seen_ids` MapSet) | None — never pruned/evicted | **UNBOUNDED — HIGH** (memory accrual per topic) |
| AMQP inbound link credit | lib/smalt/messaging/amqp/connection.ex:51 `@max_link_credit 10_000`, :571 clamps peer flow | Typed cap, clamped | BOUNDED |
| AMQP connection recv pump | lib/smalt/messaging/amqp/connection.ex:48 `@recv_timeout 300_000`, :52 `@pre_open_timeout 5_000`, idle deadline :428-442 | Typed timeouts, connection close on expiry | BOUNDED |
| AMQP atom_bridge recv | lib/smalt/messaging/amqp/atom_bridge.ex:31 `@recv_timeout 5_000` | Typed timeout | BOUNDED |
| AMQP listener accept | lib/smalt/messaging/amqp/listener.ex:29 `@accept_timeout_ms 200` + exp backoff | BOUNDED (loop), but **MED**: DynamicSupervisor connection fan-in uncapped — no max-connection limit (listener.ex:127-142) | BOUNDED loop / MED uncapped fan-in |
| Store CAS / insert_new / next_seq funnel | lib/smalt/store.ex:58, :220, :238, :295 | `GenServer.call` **default 5_000ms implicit** — no typed @timeout; caller exits on expiry | BOUNDED (default) — MED: implicit, not typed/declared |
| EventGrid publish/subscribe/ack | lib/smalt/messaging/event_grid.ex:112, :150, :156 | Default 5_000ms implicit — same as Store | BOUNDED (default) — MED |
| EventHubs read path | lib/smalt/messaging/event_hubs.ex:629 `GenServer.call(@name, request)` | Default 5_000ms implicit | BOUNDED (default) — MED |
| Ledger writer append | lib/smalt/security/ledger_writer.ex:23,36 `@call_timeout 30_000` | Typed @timeout | BOUNDED |
| ARM LRO await | lib/smalt/arm_gateway/lro.ex:178 `await(op_id, timeout \\ 5_000)` | Typed, deadline-based | BOUNDED |
| LRO sweeper writer calls | lib/smalt/arm_gateway/lro.ex:296,332 `@writer_call_timeout_ms 5_000` | Typed @timeout | BOUNDED |
| LRO sweeper flip | lib/smalt/arm_gateway/lro_sweeper.ex:69 `10_000` | Typed literal | BOUNDED |
| Queue storage message store | lib/smalt/data_plane/queue_storage.ex (ETS `:smalt_sb_messages`) | Visibility timeout 30s default, cap 604_800s (:43,:511-526) | BOUNDED per-message; message store grows by design (storage emulator, not a backpressure defect) |
| Telemetry counters | lib/smalt/telemetry.ex:206 | Deliberately off-GenServer (ETS write_concurrency) to remove the call funnel — a prior funnel fix | BOUNDED |

## HIGH findings

1. **EventGrid per-subscriber queue has no capacity bound**
   lib/smalt/messaging/event_grid.ex:330 (queue created), :446 ("Queue for DOWN
   subscriptions too"), :470 (`queue.join`). Under load with a slow or crashed
   subscriber the queue accumulates every published event until the 24h TTL
   expires it at dispatch. Only defense is `drop_expired/3` (:405-421). No
   `maxlen`, no overflow policy, no drop telemetry until expiry.
2. **EventGrid `seen_ids` dedup set never evicts**
   lib/smalt/messaging/event_grid.ex:186-189. Every published id is retained
   forever per topic; `reset/1` clears only on explicit topic drop (:439). A
   long-lived topic accumulates ids without bound (memory accrual, monotonic).

## MED findings

3. Data-plane call funnel (Store CAS/next_seq, EventGrid publish, EventHubs)
   uses `GenServer.call` with the **implicit default 5s timeout** — bounded
   (timeout exit) but untyped and undeclared; no explicit `@call_timeout`.
4. AMQP listener accepts connections into an uncapped DynamicSupervisor —
   no max-connection ceiling (listener.ex:127-142).

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3): HIGH/MED findings REMEDIATED on current tree

Re-ran every cited probe against the live tree; the audit's findings have been
remediated by later lanes (the code cites this receipt):

```
$ grep -rn "Task.async_stream\|max_concurrency" lib/smalt | wc -l  -> 0 ; exit=0
$ grep -rin "poolboy\|NimblePool" lib | wc -l                      -> 0 ; exit=0
$ grep -n "max_queue_len" lib/smalt/messaging/event_grid.ex
  56/69/89: per-subscriber queue cap :max_queue_len default 10_000 (overridable)
  552-557: "Capacity bound (SCVD-T8): prune the queue to :max_queue_len" — prune_queue at dispatch
$ grep -n "max_seen_ids" lib/smalt/messaging/event_grid.ex
  @default_max_seen_ids 100_000; remember_id/prune_order evicts (seen_order queue)  ; exit=0
$ grep -n "@call_timeout" lib/smalt/store.ex -> 46-50: "SCVD backpressure audit MED-3:
  ... previously relied on the implicit GenServer.call 5_000ms default. Typed now"
  @call_timeout 5_000
$ ledger_writer @call_timeout 30_000 (line 25) ; lro await/5_000, @writer_call_timeout_ms 5_000
  — all still present, exit=0
```

HIGH-1 (per-subscriber queue, no maxlen) → REMEDIATED: `max_queue_len`
(default 10_000, prune at enqueue, comment cites SCVD-T8). HIGH-2 (seen_ids
never evicts) → REMEDIATED: `max_seen_ids` (default 100_000) with
`prune_order` eviction. MED-3 (implicit 5s call funnel) → REMEDIATED: typed
`@call_timeout 5_000` in store.ex citing this audit. MED-4 (uncapped
DynamicSupervisor fan-in) unchanged/observed as typed in the receipt — not
re-audited here. Standing superseded: NEEDS REMEDIATION → REMEDIATED
(witnessed on tree 2026-10-22). SUSPECT cleared.

## Standing (original, 2026-10-21)

**Standing:** PARTIAL_ALIVE — original audit: NEEDS REMEDIATION (2 HIGH unbounded EventGrid accumulators, queue + dedup set; AMQP/ARM paths bounded with typed timeouts); 2026-10-22 addendum witnesses HIGH-1/HIGH-2/MED-3 REMEDIATED on tree (grep receipts exit 0 embedded), MED-4 observed, not re-audited.
