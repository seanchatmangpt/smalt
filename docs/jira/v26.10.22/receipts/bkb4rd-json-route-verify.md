# BK-B4RD — JSON child-PUT route end-to-end verify + creation-path census

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-B4RD (read-only verify; only this receipt written)
- Input: `docs/jira/v26.10.22/receipts/bkb4rc-send-gate-court.md` (BK-B4RC noted the ARM JSON child-PUT route already materializes; this lane witnesses it and censuses all creation routes)

## 1. JSON route witness (the face BK-B4RC's ATOM court does not cover)

Real route code: real Plug dispatch through `Smalt.ArmGateway.Router` —
namespace PUT (202) → child-PUT
`/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ServiceBus/namespaces/{ns}/queues/{name}` (201)
→ `handle_child_put/5` → `sb_materialize_amqp` (`lib/smalt/arm_gateway/router.ex:1858`/`2200`) →
`QueueStore.ensure_queue/1`. Then real send through the KD-86 gate
(`QueueStore.enqueue/3`) and a real `dequeue_matching/2` delivery claim.
Scratch script `tmp/bkb4rd_json_route.exs` (gitignored, removed after the run).

Embedded witness output (two fresh runs, `MIX_BUILD_ROOT=_build-bkb4rd MIX_ENV=test mix run`):

```
namespace PUT status: 202
queue PUT status: 201
{"id":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/b4rd-rg/namespaces/b4rd-ns/queues/b4rd-json-1792681847566",...
AMQP_ROW_MATERIALIZED_BY_JSON_ROUTE: %{name: "b4rd-json-1792681847566"}
SEND_DELIVERED body=b4rd-json-payload seq=1

--- run 2 (fresh unique name) ---
namespace PUT status: 202
queue PUT status: 201
AMQP_ROW_MATERIALIZED_BY_JSON_ROUTE: %{name: "b4rd-json-1792681896858"}
SEND_DELIVERED body=b4rd-json-payload seq=1
```

The row is materialized by the JSON route ITSELF (before any send), so this
route never depended on the send-gate arm BK-B4R fixed — and `sb_auto_ensure`
was `false` for the whole witness, so the delivery is not auto-create
masking. Cross-route composition (JSON-create → AMQP send) holds.

## 2. Creation-path census (who writes entity rows)

Every route that can bring an SB entity into existence, with its
materialization state at creation time:

| # | Route | Code | Materializes `:smalt_sb_queues` at creation? |
|---|---|---|---|
| 1 | ARM JSON child-PUT (`handle_child_put/5`, `sb_child_put/5`) | `lib/smalt/arm_gateway/router.ex:1858,2185` → `sb_materialize_amqp/2` → `QueueStore.ensure_queue/1` | YES — witnessed above |
| 2 | ATOM alias PUT (`AtomBridge.handle_request/3`) | `lib/smalt/messaging/amqp/atom_bridge.ex:430` — writes `:smalt_resources` ONLY | NO — admitted at send by `ensure_entity/1`'s `arm_entity?/1` arm (the BK-B4R fix, pinned by BK-B4RC court) |
| 3 | `Smalt.Arm.SbManagement.create` | `lib/smalt/arm/sb_management.ex:351-352` `materialize(:queues/:topics)` → `ensure_queue/1` | YES |
| 4 | Egress SB bridge queue | `lib/smalt/egress_router.ex:4433` `ensure_queue(@sb_bridge_queue)` | YES |
| 5 | SB rules engine pre-send | `lib/smalt/sb_rules.ex:576` `ensure_queue/1` | YES |
| 6 | Auto-create-on-send (KD-86 flag) | `lib/smalt/messaging/amqp/queue_store.ex:70,76` | YES when flag on (off by default) |

Census is complete: all entity-creation surfaces are `ensure_queue/1` callers
plus the ATOM bridge (the only non-materializing route, which the send gate
admits). No third route class found beyond management-plane (JSON/ATOM) +
send-path gate + internal bridges.

## 3. Fresh suites

`smalt-cli` real-SDK pytest (lane-private ports, `SMALT_CLI_LANE=bkb4rd-c1`):

```
$ .venv-cli/bin/python -m pytest tests/test_ty_servicebus.py tests/test_ty_storage.py -q
........                                                                 [100%]
8 passed in 11.94s
```

## Standing

ALIVE — the JSON route composes end-to-end (create 201 → row present → real
send delivers, auto-ensure off) with 2 fresh witnesses, and the creation-path
census is complete and typed (5 of 6 routes materialize at creation; the ATOM
route is the known, court-pinned exception).
