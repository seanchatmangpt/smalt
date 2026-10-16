# Bench lane B-4 — Messaging throughput, real TS SDKs over AMQP

Date: 2026-10-15/16. Repo `/Users/sac/smalt` (v26.10.14, branch `main`, HEAD
`518b31a54ccc0829cafb9e04538714e58c287a30` — **dirty tree**: sibling bench/CBD
lanes were concurrently modifying `lib/smalt/messaging/amqp/connection.ex`
(+115 lines incl. credit paths), `management_rpc.ex`, `application.ex`,
`blob_storage.ex` during the measurement window; two mid-run compile freezes
were waited out per the compile-freeze SLA).

- Harness: `scripts/bench/b4_messaging_ts.mjs` (this lane, new file)
- Results: `docs/jira/v26.10.14/bench/b4-messaging-ts.jsonl` (final full run,
  6 records; earlier regimes overwritten — see Regimes below)
- SDKs: `@azure/service-bus@7.10.0`, `@azure/event-hubs@6.0.4`, rhea `3.0.5`
  (from `test/sdk-full/node_modules`, no root install), Node v26.10.0
- Substrate: self-booted on the b4 private block 39040-39045
  (`MIX_ENV=test mix run --no-start`, anonymous auth, minted 48-byte base64
  `sb_shared_key`); CBS put-token 200 `LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY`
  witnessed; ports verified free at teardown
- Payload: 1 KiB; 5 s warmup; 30 s measured window; retries maxRetries 4
  (2 s delay), 30 s op timeout, 20 s harness op timeout

## Headline numbers (definitive run, 2026-10-16T03:35-03:37Z)

| # | surface | op | result |
|---|---|---|---|
| a | Service Bus | send, 1 KiB, sessionless queue | **50.6 msgs/s** (n=2000, p50 0.23 ms, p95/p99 in JSONL, 4 errors) |
| b | Service Bus | send + receive-complete round-trip | **50.6 round-trips/s** (n=2000, 2000/2000 completed, p50 265.7 ms, 3 errors) |
| c | Event Hubs | producer sendBatch (1 event/batch, 1 KiB) | **324.7 events/s** (n=9742, p50 3.07 ms, 0 errors, 38 producer recycles) |
| c | Event Hubs | SDK consumer | `subscribe()` now **attaches OK** (sibling KD-19 fix landed mid-session); **0 events delivered** to the SDK/rhea consumer on partition 0 — recorded as errors=0 but receive=0, see finding F4 |

Latency honest note: per-op latency is microsecond-class (0.2-3 ms p50); the
rates are wall-clock-capped by substrate-side stall episodes, not by per-op
latency.

## Findings (KD candidates, all wire-witnessed this lane)

- **F1 — sender credit never replenished.** The substrate grants a fixed
  `link_credit: 1000` to client-sender links at attach
  (`lib/smalt/messaging/amqp/connection.ex` ~:525-538) and never replenishes it
  on disposition, so every sender link is a 1000-send budget. Mitigated in the
  harness by recycling sender links every 400 sends (counted as
  `sender_link_recycles` in the JSONL).
- **F2 — session incoming-window never advanced: hard 4096 wall.** After
  exactly 4096 inbound transfers on one AMQP session, every further transfer on
  ANY link of that session goes undispositioned (15-20 s op timeouts) —
  witnessed verbatim: sends 1-4096 OK at 0.2-0.3 ms, send 4097 timed out ×3,
  recovering only on a new connection. The substrate never sends session flow
  (incoming-window updates). Fix: send session `flow` advancing
  `incoming_window`/handling delivery-id wraparound.
- **F3 — SenderBusy storms (regime-dependent).** Depending on boot, fresh
  sender links receive no usable credit (rhea `SenderBusyError: cannot send the
  message right now` on the first send, persisting across new connections for
  tens of seconds, then clearing). This capped the definitive run at ~50/s
  where an earlier regime on the same harness sent ~5,300/s inside one session.
  Failure signature shifted across boots **while sibling lanes were editing
  `connection.ex` credit paths** — the measured substrate was a moving target;
  a re-run on a settled tree is the falsifier for both directions.
- **F4 — EH consumer attaches, receives nothing.** `EventHubConsumerClient.
  subscribe()` bootstrap succeeded this run (getEventHubProperties no longer
  501 — the sibling KD-19 fix landed mid-session), but 0 events were delivered
  to a rhea receiver on `b4-hub/ConsumerGroups/$Default/Partitions/0` despite
  ~9.7k events sent to the hub minutes earlier. Consistent with KD-18/20
  (message_format/credit on the EH delivery path) plus default-position
  semantics; needs a position=earlier re-test after KD-20 lands.
- **F5 — SDK-internal CBS timer race.** `@azure/core-amqp`
  `requestResponseLink.js:107` throws uncaught `TypeError: Cannot read
  properties of undefined (reading 'address')` when a CBS request-response link
  timer fires after its session teardown (triggered by aggressive client
  recycling under load; also fires after process benches complete). The harness
  records these and continues; a benchmark that dies on an SDK timer race
  measures nothing. Recorded in the JSONL `uncaught-exceptions` record.

## Regimes (honest provenance)

The same harness produced materially different regimes across the session:

| regime | (a) send | (b) round-trip | notes |
|---|---|---|---|
| early (pre-fix runs) | ~5,300/s bursts until F2's 4096 wall | 122/s, p50 4.0 s (lock/redelivery churn, rhea `Received transfer when credit was 0` stderr storm) | n=0 recorded because all 4096-send budget was consumed in warmup |
| mid | 0-2.2/s (SenderBusy storms) | 289/s (client recycles at 3000 sends) | |
| definitive | 50.6/s | 50.6/s, 2000/2000 completed | recorded in the JSONL |

The JSONL on disk holds only the definitive run; regime table above is
session-provenance, not re-runnable numbers.

## Falsifiers

- F1/F2: a lib fix that replenishes sender credit on disposition and advances
  the session incoming-window should collapse the harness's recycle machinery
  to a no-op and (a) should exceed 1,000 msgs/s in the same 30 s window.
- F3: on a settled tree (no concurrent `connection.ex` edits), two consecutive
  boots should produce rates within noise of each other.
- F4: after KD-20 lands, a rhea receiver on partition 0 should receive the
  ~9.7k previously-sent events (position=earlier) with
  `x-opt-sequence-number` strictly increasing.

## Harness notes

- Per-op timeout races + bounded closes: the SDK CBS race (F5) can leave an
  awaited send permanently pending; without them the bench hangs instead of
  measuring.
- `uncaughtException` guard records and continues; count lands in the JSONL.
- Client recycle every 3000 sends (F2 mitigation), sender link recycle every
  400 sends (F1 mitigation).
- The EH SDK consumer arg contract is `EventHubConsumerClient(consumerGroup,
  connectionString, eventHubName)` — a wrong-arg-order bug in this harness
  produced a misleading "Connection string malformed" error earlier in the
  session (fixed here; recorded because census-style harnesses can hit it).
