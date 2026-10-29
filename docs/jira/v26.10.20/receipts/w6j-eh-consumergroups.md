# W6J — Event Hubs consumer groups: ARM face raise (wave-6 lane w6j)

**Standing:** **ALIVE** (witness EXIT=0, all 22 checks true; 9/0 tests)

Date: 2026-10-20 · Lane: w6j · Milestone: v26.10.20

## Surface

`/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.EventHub/namespaces/{ns}/eventhubs/{hub}/consumergroups[/{name}]` —
PUT/GET/DELETE/LIST, directive-pinned semantics (w6j pin):

| verb | case | result |
|---|---|---|
| PUT | `$default` | 400 `ConsumerGroupNotCreatable` |
| PUT | new group | 201 + engine create + Store mirror |
| PUT | existing, same userMetadata | 200 idempotent (created-ts preserved) |
| PUT | existing, changed userMetadata | 409 `ConsumerGroupConflict` |
| GET | unknown | 404 `ConsumerGroupNotFound` |
| DELETE | `$default` | 400 `ConsumerGroupNotDeletable` |
| DELETE | unknown | 404 `ConsumerGroupNotFound` |
| LIST | always | `$default` synthesized exactly once (shim-court cg-default preserved) |
| any | envelope | `properties.userMetadata` echoes verbatim |

## What landed

- **`lib/smalt/arm/eh_consumergroups.ex`** (NEW): self-contained verb bodies
  (`put/get/delete/list`), own envelope builder (shape-identical to the
  router's `build_resource_record` output), typed faces, `$default`
  immutability 400s, duplicate-PUT 409, user-metadata echo. Store mirror on
  every mutation; engine stays source of truth for existence/created-ts.
- **`lib/smalt/arm_gateway/router.ex`**: `handle_cg_engine/7` now delegates
  verb bodies to `Smalt.Arm.EhConsumerGroups` (router keeps the admission
  gates: api-version / shape / properties-member); `:list_cg` branch in
  `handle_parented_child` delegates to `EhConsumerGroups.list/2` directly;
  retired `handle_cg_list/5` + cg helper block (dead code removal, ERRC).
  Shim-court cg-default LIST semantics preserved byte-identically.
- **`test/integration/arm_consumer_group_bridge_test.exs`**: pinned faces
  updated to the w6j pinion — `$default` PUT/DELETE → 400 (was 409 engine
  face), same-metadata re-PUT → 200, changed-metadata re-PUT → 409
  `ConsumerGroupConflict`. 9 tests, 0 failures.
- Internal engine test (`test/internal/event_hubs_consumer_groups_test.exs`)
  untouched — the messaging-plane engine face stays 409
  `ConsumerGroupNotDeletable`; ARM plane answers 400 per the work order
  (plane-faces documented divergence, receipt-pinned here).

## Witness (real output, EXIT=0)

Replay: `MIX_ENV=test MIX_BUILD_ROOT=_build-lane-w6j mix run --no-start tmp/w6j_witness.exs`

```
NS_PUT_OK=true          (202 LRO — KD-111 widening; accepted)
HUB_PUT_201=true
PUT_201=true
META_ECHO=true
ENGINE_EXISTS=true
REPUT_200=true
CREATED_TS_PRESERVED=true
CONFLICT_409=true
CONFLICT_CODE=true
DEFAULT_PUT_400=true
DEFAULT_PUT_CODE=true
GET_404=true
GET_404_CODE=true
DEFAULT_DEL_400=true
DEFAULT_DEL_CODE=true
LIST_200=true
LIST_HAS_DEFAULT_ONCE=true
DELETE_200=true
ENGINE_GONE=true
GET_AFTER_404=true
DELETE_MISS_404=true
W6J WITNESS DONE
```

## Gates

- `MIX_BUILD_ROOT=_build-lane-w6j mix compile` → exit 0 (zero warnings in
  `eh_consumergroups.ex`; residual warnings-as-errors failures are sibling
  lanes' in-flight files, none in w6j files)
- `mix test test/integration/arm_consumer_group_bridge_test.exs
  test/internal/event_hubs_consumer_groups_test.exs` → **9 tests, 0 failures**

## Disclosures

- **Compile-freeze SLA**: my deletion of the retired `handle_cg_list/5`
  block over-reached and briefly removed `handle_cg_engine/7` (two dangling
  call sites, tree frozen on router.ex for several polls). The escalating
  lane flagged it; fixed within the SLA window by restoring the delegating
  handler + rewiring `:list_cg` to `EhConsumerGroups.list/2`. Coordinators
  should read the freeze window as w6j-owned.
  - Second, unrelated mid-lane correction: an earlier witness-script draft
    used nested-quote string interpolations that failed to parse; rewritten
    with a `check/2` helper (scratch file only, not tree surface).
- **No unblock fixes to other lanes' files** — all sibling breakage
  (table_storage, egress_router, egress/*Routes, arm/dns, deployments,
  eh_schema_registry, cosmos_analytical_ttl) self-repaired by their owners
  inside the SLA.
- Scratch: `tmp/w6j_witness.exs` + `tmp/w6j_witness.out` (replayable).

## Falsifier

Reverting `EhConsumerGroups.put/2`'s `$default` guard flips
`DEFAULT_PUT_400=true` → false and re-fails the updated pinion legs in
`arm_consumer_group_bridge_test.exs` ("$default is immutable over ARM").

Context: solo
