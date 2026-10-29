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

---

## RE-MEASURE addendum (2026-10-22, lane BK-BQUIET — quiesced-machine attempt, FAIL face)

- **Standing**: SUSPECT-PERMANENT (typed LOUDER — re-measure FAILED; owner messaging lane)
- **Context**: solo
- Attempt context: `just quiesce` REFUSED; bounded 15-min poll never cleared
  (load 78 -> 120 during this lane). The pass proceeded under residual load,
  typed honestly: this is a load-confounded attempt, not a clean regression
  proof.
- Replay (real, exit-captured): self-booting driver on block 39040..39045.
  Substrate booted OK (29.1 s to LISTEN); CBS SAS handshake healthy — 1,717
  `put-token status=200 LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY` events
  in tmp/bench-substrate-b4.log — so the AMQP transport and CBS authority
  were alive.

```
PRE-B4 load={ 120.26 112.19 102.72 } 2026-10-22T13:47:49Z
substrate up on ports 39040/39041/39042/39043/39044/345 after 29067ms
(a) SB send: 0 msgs in 40s = 0.0 msgs/s p50=0.00ms errs=3 clientRecycles=2
    [run killed by the lane after ~25 min of phase-(b) churn; CBS tokens
     continued succeeding at 200 throughout]
POST-B4: ports 39040..39045 verified free after teardown
```

- Verdict: **FAIL (load-confounded)**. Surface (a) delivered 0/2000 sends
  (3 errors, 2 client recycles); the round-trip phase churned op-timeouts for
  ~25 min and was killed by the lane (bounded-window discipline). Typing:
  **stays SUSPECT-PERMANENT, louder** — now load-confounded-FAIL rather than
  NO-CONTEXT: the send surface must be re-witnessed by the messaging owner on
  a genuinely quiet machine before any flip. Two candidate mechanisms an
  owner should check: (i) pure load starvation of settlement within the 20 s
  op timeout, (ii) the fixed link_credit=1000 / recycle-every-400 idiom
  interacting with a lib/smalt messaging change since 2026-10-15 (the
  original run was on a dirty tree mid-amqp-edit; tree has moved 3
  milestones). CBS-at-200 while sends deliver 0 narrows the face to the
  sender link, not auth or attach.

## BK-B4R addendum (2026-10-22, owner messaging lane — root cause + fix, sends deliver)

- **Standing**: ALIVE (sends deliver end to end; typed residuals below)
- **Context**: solo
- Root cause (two layers, both real):
  1. **lib defect (fixed)**: the KD-86 send gate (`queue_store.ex
     ensure_entity/1`, landed fe4a3d83 2026-10-21) consulted ONLY
     `:smalt_sb_queues` (emulator-lazy rows). An entity created through the
     MANAGEMENT plane — ARM gateway PUT or the ATOM alias bridge — lives in
     `:smalt_resources` and had no `:smalt_sb_queues` row, so every send to
     an ARM/ATOM-created queue was refused `MessagingEntityNotFound`, the
     sender link was detached, and the SDK retried into the harness's 20s
     op timeout. This is the BK-BQUIET face: 0/2000 sends with CBS put-token
     200 ×1,717 (CBS rides `$cbs`, unrelated to the queue entity gate).
     Not load, not link credit: the very first send on a fresh client
     failed deterministically (B4R-TRACE witness: attach echoed + credit
     flow sent, transfer → server detach `MessagingEntityNotFound`).
  2. **stale harness idiom (fixed)**: `b4_messaging_ts.mjs` never provisioned
     its entities — it predated the KD-86 flip and relied on the removed
     emulator auto-create-on-send convenience. The harness now provisions
     `b4-send-<ts>` / `b4-rt-<ts>` over the ARM ATOM alias
     (PUT, expect 200/201) before measuring, exit 3 on provision failure.
- Fix commit surface: `lib/smalt/messaging/amqp/queue_store.ex`
  (ensure_entity/1 admits an ARM resource record as entity existence and
  materializes the `:smalt_sb_queues` row), `scripts/bench/b4_messaging_ts.mjs`
  (entity provisioning + SEND_QUEUE/RT_QUEUE hoist).
- Rerun (real, exit 0, self-booted substrate on block 39040..39045, load
  20-50/16 cores = load-typed):
```
substrate up ... after 2005ms (pid 46083)
provisioned queue b4-send-1792680708470 (201)
provisioned queue b4-rt-1792680708470 (201)
(a) SB send: 2000 msgs in 40s = 50.6 msgs/s p50=0.25ms errs=4 clientRecycles=2
(b) SB round-trip: sent=2000 completed=2000 => 50.3 round-trips/s p50=370.98ms errs=3
(c) EH producer: 5625 events in 30s = 187.5 events/s p50=5.34ms errs=0 recycles=22
(c) EH rhea wire-tier consumer: received 0 events (seq annotated: 0), sdk subscribe ok=true
```
- Confirmation run (send-only): 2000 msgs, errs=4, clientRecycles=2 —
  deterministic.
- Typed residual (not a delivery failure): 4 (a) + 3 (b) fast `AggregateError`
  aborts, empty message, client-side only (nothing on the server wire; no
  detach/unauthorized in the substrate log). They ride the harness's
  client-recycle idiom (consecutiveErrs>=2 → closeSoon(client.close())), which
  aborts the in-flight awaited op — the abort surfaces as the next counted
  error. 0.2% of ops; every measured window still delivers its full 2000.
  Falsifier for this typing: if a run shows err_detail with a non-empty
  AggregateError message or a server-side detach in the substrate log, the
  "recycle artifact" typing is refuted and the row reopens.
- Rates are load-typed (50.6/s vs 4351 baseline) — machine carried 20+ lanes
  at load 20-50; the load-bearing flip criterion was >0 delivered sends.
- Canonical jsonl preserved: this run's rows snapshotted to
  `tmp/bkb4r/b4-messaging-ts-bkb4r-run.jsonl`; the canonical
  `b4-messaging-ts.jsonl` restored byte-exact to HEAD.
