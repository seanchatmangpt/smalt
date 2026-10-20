# Receipt — w2i lane: ARM Service Bus topic/subscription face (b6 enforce witness)

- **Date**: 2026-10-20
- **Lane**: w2i (ERRC CREATE — Azure capability)
- **File ownership**: `lib/smalt/arm_gateway/router.ex` (SB topic/subscription routes + handlers, additive)
- **Context**: solo (single lane on the tree; shared `lib/` compile freezes from other lanes' in-flight files observed twice — certificates.ex, egress_router.ex — resolved by their owners within the SLA window; disclosed per compile-freeze disclosure law)
- **Standing**: **PARTIAL_ALIVE** — full ARM CRUD + defaults hydration + AMQP entity materialization witnessed green over real dispatch with enforce auth; the AMQP fan-out bridge (topic → subscription delivery) is an OPEN typed gap in the delivery engine (outside this lane's file ownership).

## Diff

`lib/smalt/arm_gateway/router.ex` (+312/−10 vs HEAD, includes a concurrently-landed
w2j consumer-group bridge in the same file — not this lane's work):

- 8 SB topic/subscription routes re-pointed from `handle_parented_child` to the new
  SB-aware `handle_sb_child/7` (same parent-existence gate + refusal-tier ordering,
  same `:smalt_resources` storage — behavior-compatible superset).
- `@sb_topic_defaults` / `@sb_subscription_defaults` hydration (user-wins deep merge,
  same contract as `Defaults.apply/2`): topic `maxSizeInMegabytes 1024`,
  `defaultMessageTimeToLive P14D`, `status/supportOrdering/enableBatchedOperations`;
  subscription `lockDuration PT5M`, `maxDeliveryCount 10`,
  `defaultMessageTimeToLive P14D`, `requiresSession false`,
  `deadLettering onMessageExpiration false`.
- AMQP entity materialization on PUT: topic → `QueueStore.ensure_queue(name)`;
  subscription → `ensure_queue("<topic>/Subscriptions/<sub>")` (the exact attach
  address the Azure SDKs use). DELETE tears down the entity row(s)
  (`:smalt_sb_queues`); in-flight `:smalt_sb_messages` rows are left to the sweeper
  (direct ETS message surgery would race a concurrent claim).
- Typed fan-out gap documented at `handle_sb_child/7` module doc: send to topic
  lands in the queue-backed topic entity; receivers on
  `<topic>/Subscriptions/<sub>` attach cleanly but receive 0 messages until the
  delivery engine fans out. Fan-out belongs in `connection.ex`/`queue_store.ex`
  (not this lane's files).

## Witness — b6 enforce (exit 0, 15/15 steps PASS)

Command: `verification/py/.venv/bin/python tmp/w2i/w2i_b6_witness.py` against a
private-port substrate (ARM 39060, AMQP 39062, `auth_mode :enforce`,
`SMALT_SB_SHARED_KEY` dev derivation), real `azure-servicebus 7.15.0` SDK leg
(verification/py venv):

```
PASS sts-mint :: POST /w2i-tenant/oauth2/v2.0/token -> 200
PASS rg-put :: PUT RG -> 201
PASS ns-put-lro-202 :: PUT namespace -> 202
PASS topic-put-201 :: PUT topic -> 201
PASS topic-defaults :: maxSizeInMegabytes=1024 defaultMessageTimeToLive=P14D
PASS topic-get :: GET topic -> 200
PASS sub-put-201 :: PUT subscription -> 201
PASS sub-defaults :: lockDuration=PT2M maxDeliveryCount=10 defaultMessageTimeToLive=P14D
PASS topics-list :: LIST topics -> 200 value=2
PASS subs-list :: LIST subscriptions -> 200 value=1
PASS sdk-send-topic :: SDK send to topic 'w2i-orders' accepted (queue-backed materialized entity)
PASS sdk-sub-receive :: receiver on 'w2i-orders/Subscriptions/w2i-main' attached; 0 messages (fan-out bridge gap OPEN — expected 0 until engine fan-out lands)
PASS sub-delete :: DELETE subscription -> 200
PASS topic-delete :: DELETE topic -> 200
PASS topic-get-404 :: GET deleted topic -> 404
EXIT=0
```

Scratch drivers: `tmp/w2i/w2i_b6_boot.sh` (substrate boot) +
`tmp/w2i/w2i_b6_witness.py` (witness); tmp/ is scratch, this receipt is the indexed
record.

## Verification ladder

- Compile: `MIX_BUILD_ROOT=_build-lane-w2i mix compile --warnings-as-errors` → exit 0, zero router warnings.
- Internal tier: `MIX_BUILD_ROOT=_build-lane-w2i mix test test/internal/arm_consumer_group_bridge_test.exs test/internal/internal_tier_census_test.exs` →
  `6 tests, 0 failures` (earlier in-session 7 failures were the w2j lane's in-flight
  `handle_cg_engine` state in the same shared file, since resolved by its owner —
  re-run green without any change from this lane).
- Pre-existing face (NOT introduced here, observed during diagnosis): a child PUT
  body without a `location` member (e.g. `{}`) answers 400 InvalidResourceShape
  "A resource payload may carry at most one location." from GraphLaw shape
  validation — applies to queues/topics/subscriptions alike at HEAD behavior.

## Falsifiers / open items

- F-w2i-1: fan-out bridge — `send to topic` does not deliver into
  `<topic>/Subscriptions/<sub>` entities. Witness step `sdk-sub-receive` observes 0
  messages; closes only with an engine-side fan-out landing (connection.ex /
  queue_store.ex ownership).
- F-w2i-2: child-PUT `{}` shape refusal (pre-existing, above) — candidate KD row,
  not minted unilaterally.
