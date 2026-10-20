# kd101-eg-webhook-receiver.md — work-order receipt (ERRC lane C3, 2026-10-20)

- **KD row**: KD-101 (Event Grid delivery) — NARROWED
- **Standing**: ALIVE — receiver surface landed + executed (10/10 tests green,
  compile warning-clean; remaining divergence registered honestly)
- **Subject**: smalt working tree, lane build root `_build-lane-c3`, MIX_ENV=test
- **Context**: pair (concurrent lanes active on the shared tree)

## What landed

- **NEW** `lib/smalt/event_grid_webhook.ex`:
  - `Smalt.EventGridWebhook` — receiver registry GenServer (lazy-start,
    QueueStore pattern): `register/2`, `unregister/1`, `delivered/1` (pull API),
    `delivered?/2`, `reset/0`; CloudEvents 1.0 validation
    (`validate_events/1`); delivery core (`deliver/3`) — SubscriptionValidationEvent
    batches answered `{"validationResponse": code}` and NOT delivered; real
    events delivered as `{:event_grid_webhook, subscriber, id, event}` to the
    registered pid + recorded (ring buffer, newest 1000, with aeg-*/handler
    metadata + delivered_at) for pull.
  - `Smalt.EventGridWebhookPlug` — mountable, zero-auth `/eventgrid` path
    class: `WebHook-Request-Origin` handshake on any method (answers
    `WebHook-Allowed-Origin` + `WebHook-Allowed-Rate` echo, honors
    `WebHook-Event-Handler-Version`), `POST /eventgrid/hooks/:subscriber`
    delivery/validation, typed 404 `UnknownSubscriber` / 400
    `InvalidCloudEvent` / 400 `InvalidJsonBody` / 413 `BodyTooLarge`.
  - NOT mounted (this lane did not touch `egress_router.ex` / arm router).

## Mount-point handoff (one-liners, coordinator-owned files)

Mount the plug BEFORE auth/parsers in the router chain:

1. `lib/smalt/egress_router.ex` — add `plug(Smalt.EventGridWebhookPlug)`
   immediately before line 118's `plug(Smalt.Auth.Bearer)` (after
   `plug(:kv_challenge_guard)`); matches only the `/eventgrid` path class and
   passes everything else through untouched.
2. `lib/smalt/arm_gateway/router.ex` (if the ARM twin 9444 surface should
   serve the receiver too) — same placement, before its Bearer plug.

## Execution receipt

```
$ MIX_BUILD_ROOT=_build-lane-c3 MIX_ENV=test mix compile --warnings-as-errors (module-scoped grep for event_grid_webhook)
0
event_grid_webhook hits: ^ (0 = warning-clean for this lane's module)

$ MIX_BUILD_ROOT=_build-lane-c3 MIX_ENV=test mix test test/integration/event_grid_webhook_test.exs
..........
Finished in 0.1 seconds (0.00s async, 0.1s sync)
10 tests, 0 failures

$ MIX_BUILD_ROOT=_build-lane-c3 MIX_ENV=test mix test test/internal (shared tree, concurrent lanes in flight)
     test/internal population drifted: on_disk=[...other lanes' new files...]
29 tests, 6 failures  <- ALL 6 from other lanes' in-flight files
     (certificates_kd104_witness_test.exs, event_hubs_consumer_groups_test.exs,
      vm_zero_growth_test.exs churn); census violation lists contain ZERO
      event_grid_webhook entries (grep -c event_grid_webhook = 0).
```

## Compile-freeze disclosures (SLA rule 2)

- Concurrent-lane mid-edit files (kql.ex, key_vault_actions.ex, blob_storage.ex,
  purview_atlas.ex, certificates.ex) broke the shared compile repeatedly for
  ~25 min; this lane polled-and-retried (compile loop, bounded) rather than
  editing another lane's files — no cross-lane edit was ultimately needed; the
  tree went green on its owner's next write. No foreign-file diff from this lane.

## Falsifier / witness shape

Falsifier re-executed at the receiver face: registered in-proc subscriber
receives the handshake (200 + `WebHook-Allowed-Origin`/`-Rate`) AND a delivered
CloudEvent (in-proc message + pull record with aeg-* metadata) — both witnessed
by the 10-test suite (handshake, validation echo, delivery roundtrip, typed
refusals, single/batch bodies, pass-through for non-eventgrid paths).

## Register impact

KD-101 row narrowed in `docs/jira/v26.10.19/KNOWN_DIVERGENCES.md` (receiver
face closed by this receipt; remaining divergence = push-to-REMOTE-subscriber,
impossible under the air-gap law — permanent typed divergence). Status cell
`OPEN (narrowed)` — a full OPEN->CLOSED-SIMULATED flip is `kd_flip.py`-gated
and intentionally NOT taken here (no `# KD-COVERS` shim; the receiver is a
surface, not a divergence-covering shim).

## Cross-links

- `docs/jira/v26.10.19/receipts/kd101-eg-webhook-tbd.md` (typed-absence witness)
- `docs/jira/v26.10.14/receipts/azb-07-integration-plane.md` (in-proc contract + DLQ)
- `lib/smalt/messaging/event_grid.ex` (integration-plane fan-out, read-only to
  this lane — no edit required; the receiver is a separate face)
