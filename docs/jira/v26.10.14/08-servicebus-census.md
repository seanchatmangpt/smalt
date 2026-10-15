# V261014-08 — Service Bus: lockDuration defect, census gaps, wire-parity doc'd UNSUPPORTED

- **Release:** v26.10.14 · **Status:** PLANNED
- **Corpus refs:** `test/sdk-smoke/census.test.cjs` (8 registered probes, :261-270), `test/redteam/r3_amqp/amqp_adversary.test.cjs` + `findings.md` (46 attacks claimed / 43 on disk)

## 0. Summary

Three bounded closures + two typed-UNSUPPORTED decisions, then census growth:

1. CLOSE — queue lockDuration ignored on delivery (budget hack in census harness).
2. CLOSE — `com.microsoft:receive-by-sequence-number` (deferred receive) absent.
3. CLOSE — dead-letter-properties on update-disposition dropped.
4. TYPE — session reply-to (`reply_to` / `reply_to_session_id`): UNSUPPORTED this window, documented.
5. TYPE — subscription rules (add-rule / remove-rule / filter eval): UNSUPPORTED, documented.

Acceptance gate: census at 11 registered probes, green over the real `@azure/service-bus` SDK; WIRE_PARITY + C5/C7 carry tokenized UNSUPPORTED entries for reply-to and rules; r3_amqp findings count drift reconciled.

## 1. Verified defect — lockDuration ignored on delivery

`deliver_to_link/2` (`connection.ex:1101`) calls `QueueStore.dequeue_matching(link.address, session_id: link.session_id)` without `:lock_duration_ms`, although `dequeue_matching/2` supports it (`queue_store.ex:268-273`). Every delivery uses the default (30000 ms); the queue's configured ARM `lockDuration` is never applied to the delivery claim path. Visible symptom: the census harness budget workaround exists only because of this (`census.test.cjs:15-25`: `LOCK_DURATION_MS` hardcoded 30_000, stale-handle probe gets +5000).

### Task 08-1 — pass configured lock duration through delivery
Files: `connection.ex`, `queue_store.ex`
- Resolve the queue's configured LockDuration in `deliver_to_link/2` (expose a settings lookup facade if `queue_settings/1` is private) and pass `:lock_duration_ms` into `dequeue_matching/2`.
- No store-side change expected beyond the facade; do not change clamp semantics (100–30 000 ms).
- Remove/rewrite the census budget hack once effective duration equals the created queue's lockDuration; create the probe-6 queue with an explicit short lockDuration (e.g. 15 s) and assert expiry lands on that schedule, not 30 s.

## 2. GAP 1 — receive-by-sequence-number (deferred receive)

Deferral exists end to end: `QueueStore.defer/3` (`queue_store.ex:312`, `do_defer` :486-490 sets `state: :deferred`), `update-disposition "defered"` (`management_rpc.ex:281-282`), `claim_candidates` excludes deferred (:445). But `normalize_op/1` (`management_rpc.ex:298-310`) has no `com.microsoft:receive-by-sequence-number` — the real SDK's `receiveDeferredMessages` throws :unknown. Deferred messages are unreachable.

### Task 08-2 — add receive-by-sequence-number
Files: `management_rpc.ex`, `queue_store.ex`, `connection.ex`, `census.test.cjs`
- `normalize_op/1`: map both bare-string and `{:symbol, _}` forms to `:receive_by_sequence_number` (pattern :298-310).
- Handler: resolve entity like `renew_session_lock/5` (:140-162); required body field `sequence-numbers` (long array), optional `receiver-settle-mode`, `associated-link-name`. Blank seq list → 400.
- `QueueStore.receive_deferred/2` returning `{:ok, [msg]}` for deferred messages; missing seq → typed error surfaced as 410 MESSAGE_NOT_DEFERRED for the batch (document chosen semantics in the moduledoc).
- Re-receive re-enters the normal lock path: register a fresh lock via LockManager so complete/abandon/renew behave identically to a live delivery. Response carries `"messages"` with the peek-message envelope shape (extend/reuse that encoder).
- Census probe (new, "deferred-receive"): send → defer → receive-by-sequence-number → complete; assert exactly one delivery, body equality, gone after complete.

## 3. GAP 3 — DLQ custom properties dropped

`deadletter/5` handling (`management_rpc.ex:333-344`) forwards only `dead-letter-reason` / `dead-letter-description`; `apply_disposition("suspended", ...)` (:274-279) ignores the `dead-letter-properties` body map. (App props do survive via `queue_store.ex:536-537` but untested — `census.test.cjs:213-235` asserts only reason + body.)

### Task 08-3 — accept and merge dead-letter-properties
Files: `management_rpc.ex`, `queue_store.ex`, `delivery_encoder.ex`, `census.test.cjs`
- Read `dead-letter-properties` (map string→primitive) in the "suspended" disposition; merge into the deadletter call; default `{}` keeps current behavior.
- Extend `deadletter/4/5` to persist the properties map (additive field).
- On DLQ-side delivery, surface DeadLetterReason / DeadLetterErrorDescription / custom map under the Azure-standard application-property keys. Do NOT change the live-message baseline (`build_properties` :82-86 emits only message_id + creation_time — that stays until the reply-to window).
- Extend the dead-letter probe to deadletter with custom props and assert reason, description, AND custom props on DLQ receive.

## 4. GAP 2 + GAP 4 — typed UNSUPPORTED this window

### Task 08-4 — session reply-to: UNSUPPORTED, documented
Files: docs only (token entries) — no behavior change.
No code path stores or emits `reply_to` / `reply_to_session_id` today (`ingest_single_message` :705-738 forwards only body/session/message_id/app_props; `build_properties` :82-86 emits message_id + creation_time). Add tokenized UNSUPPORTED ("servicebus: session reply-to / reply_to_session_id") in WIRE_PARITY + C5/C7 with the deviation note: SDKs setting `reply_to_session_id` on a requires-session queue observe the field dropped, not rejected. Scoped-and-parked fix (store on ingest, emit in build_properties, census probe) recorded for next window.

### Task 08-5 — subscription rules: UNSUPPORTED, documented
Files: docs only.
`route/2` (:548-560) has no subscription concept; no add-rule/remove-rule ops in `normalize_op/1`; no filter evaluator. Feature-scale. Tokenize UNSUPPORTED for "servicebus: subscription rules (add-rule / remove-rule / SQL filter / correlation filter / default rule $Default)"; state that add-rule stays `:unknown-op` (existing fail-closed).

## 5. Corpus drift reconcile

### Task 08-6 — r3_amqp findings.md count drift
Files: `test/redteam/r3_amqp/findings.md`
findings.md reports "46 attacks, 43 kill-tests" (:9) but `amqp_adversary.test.cjs` registers fewer on disk. Reconcile: (a) restore the missing registrations if dropped, or (b) correct findings.md to the on-disk count with a dated note. Do not edit attack bodies to make counts match. Add a cross-link to V261014-08.

## 6. Sequencing

1. 08-1 (lockDuration) first — un-hacks the census budget constants the new probes inherit.
2. 08-2 and 08-3 independent of each other after 08-1.
3. 08-4/08-5 doc tokens before 08-6 so referenced docs exist.
4. Census grows 8 → 11 ("deferred-receive", "dlq-properties" registered; dead-letter probe becomes dlq-properties).

## 7. Acceptance criteria

- [ ] `dequeue_matching` receives `:lock_duration_ms` from configured entity settings; budget hack removed/rewritten.
- [ ] receive-by-sequence-number: both wire forms mapped; deferred messages re-lockable and completable; "deferred-receive" probe green.
- [ ] dead-letter-properties merged; custom props observable on DLQ receive; extended probe green.
- [ ] Census: 11 registered probes green over real SDK, zero probe-timeout false positives.
- [ ] WIRE_PARITY + C5/C7 carry the two UNSUPPORTED tokens.
- [ ] findings.md count drift reconciled with dated note or restored registrations.
- [ ] Full suite green; no regression in exclusive-session / renewal-peek / stale-handle probes.

## 8. Out of scope

Session reply-to implementation; subscription rules engine; lock-clamp changes; peek-encoder changes beyond reuse for receive-by-sequence responses.
