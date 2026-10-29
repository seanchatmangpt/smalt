# w6aj — Service Bus ARM management face (queues/topics)

**Standing:** PARTIAL_ALIVE

## Subject

- `lib/smalt/arm/sb_management.ex` (NEW, exclusive lane file) — Azure Service
  Bus ARM management parity: namespace-scoped queues/topics list/create/get/
  delete, delegating to the real stores as single source of truth:
  `:smalt_resources` (ARM records, downcased ARM-id key — the rows the AMQP
  engine's `queue_settings/1` reads for lockDuration/maxDeliveryCount) and
  `:smalt_sb_queues` (AMQP entities, materialized at create via
  `QueueStore.ensure_queue/1`, torn down at delete; topic delete also tears
  down `topic/Subscriptions/*`, mirroring the arm_gateway sb_child_delete
  contract).
- `tmp/w6aj_router_patch.md` — staged post-split mount (ROUTER HOLD honored:
  zero edits to egress_router.ex / arm_gateway/router.ex).
- `tmp/w6aj_witness.exs` + `tmp/w6aj_witness.out` — witness + real output.

## Witness (real output, module-direct over real Store + real AMQP entities)

```
CREATE_QUEUE_OK
DUP_409_OK
INVALID_BODY_400_OK
INVALID_NAME_400_OK
GET_ECHO_OK
GET_404_OK
LIST_OK
TOPIC_TEARDOWN_OK
DELETE_404_OK
W6AJ WITNESS: ALL GREEN
```

All nine legs green: create+defaults-echo (user lockDuration PT2M /
maxDeliveryCount 7 win over defaults), duplicate 409, malformed body 400
(type-guarded, no crash), oversized name 400, get echo exact,
get/delete 404 faces, list scoped to namespace+kind (other namespace and
topics excluded), topic entity materialized + `Subscriptions/*` torn down on
topic delete, queue delete → entity gone, repeat-delete 404.

## Verification

- Standalone compile: `elixirc` RC=0 (exit 0), beam emitted (only expected
  collaborator warnings). Recompiled after the defect fix; syntax gate clean.
- Full lane compile: **BLOCKED by sibling churn** — 25 bounded-poll attempts
  over ~10 min each failing in FOREIGN mid-edit files (cosmos_sql.ex,
  cosmos.ex, cbs_router.ex, rbac.ex — rotating owners), plus undefined
  `handle_cg_list/5`/`handle_cg_engine/7` in the arm router mid-add. Not
  session-introduced; disclosed per SLA. The witness ran against a real
  standalone closure: config/store_tables/store/queue_store + the module.
- Defect found + fixed in-lane (witness-caught): list_entities mapped
  `to_wire/1` over `{key, record}` tuples → every list response was `[]`.
  Leg 7 caught it; the green list legs are the non-vacuity proof.

## Replay

```
mkdir -p tmp/w6aj_ebin
elixirc -o tmp/w6aj_ebin lib/smalt/config.ex lib/smalt/store_tables.ex lib/smalt/store.ex
elixirc -o tmp/w6aj_ebin lib/smalt/messaging/amqp/queue_store.ex
elixirc -o tmp/w6aj_ebin lib/smalt/arm/sb_management.ex
ARGS=(); for d in _build-lane-w6aj/dev/lib/*/ebin; do ARGS+=(-pa "$d"); done
elixir "${ARGS[@]}" tmp/w6aj_witness.exs
```

## Falsifier (integration)

Rerun `tmp/w6aj_witness.exs` on the quiesced green tree; the list legs and
teardown legs are the falsifier for the list-mapping fix. Flip to ALIVE at
integration when the full-app compile + internal tier run green.
