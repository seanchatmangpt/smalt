# w6bd — Service Bus topic subscriptions ARM child face

**Standing:** PARTIAL_ALIVE (module+witness ALIVE on the real stores; tree-wide strict compile blocked only by sibling-owned warnings)
Context: solo
Date: 2026-10-20

## Surface

Additive extension of `lib/smalt/arm/sb_management.ex` (w6aj surface): topic-subscriptions ARM child face.

- `list_subscriptions/2` — real `:smalt_resources` enumeration, sorted; 404 unknown topic.
- `create_subscription/4` — defaults merged UNDER user body; ARM record persisted; AMQP entity materialized at `<topic>/Subscriptions/<sub>` in `:smalt_sb_queues` via `QueueStore.ensure_queue/1` (same seam as w6aj's create path — the delivery engine honors it).
- `get_subscription/3` — exact properties echo.
- `delete_subscription/3` — ARM record + AMQP row removed; 404 absent.
- `list_rules/3` — read-only delegation to the landed `RuleStore` (w6m).
- Typed errors: 400/404/409 as `{:error, {:arm_error, status, code, message}}`.

## Witness (real output, module-direct over real stores)

Replay: `MIX_BUILD_ROOT=_build-lane-w6bd MIX_ENV=test mix run tmp/w6bd_witness.exs`

```
CREATE_ECHO=true
ENGINE_REGISTERED=true
SETTINGS_HONORED=true
GET_ECHO=true
DUP_409=true
UNKNOWN_TOPIC_404=true
RULES_LIST=true
RULES_404=true
LIST=true
DELETE_AMQP_GONE=true
DELETE_404=true
TOPIC_CASCADE_INTACT=true
W6BD WITNESS: DONE
```

12/12 legs true, 0 FALSE. Grep-verified: `grep -cE "=true"` → 12, `grep -c FALSE` → 0.

## Falsifier

Green under a broken face would fail ENGINE_REGISTERED / DELETE_AMQP_GONE / TOPIC_CASCADE_INTACT — these are the non-vacuity legs.

## Verification notes

- sb_management.ex: 0 errors (isolated compile; expected isolation warnings only).
- Tree-wide strict compile blocked by sibling-owned warnings (export_template.ex, rbac.ex, egress_router static-website duplicate head, AppConfigRoutes) — not session-introduced, owners active.
- Two defects found and fixed in-lane, both witness-caught: (1) `list_rules/3` re-piped the `{:ok, list}` tuple into Enum (Protocol.UndefinedError); (2) `sub_name_from_id/1` split on the id's LEADING `/subscriptions/` prefix, returning the whole ARM path as the name (fixed to List.last).
- `_build-lane-w6bd` left for coordinator `just lane-clean`. No git; no mocks; no Process.sleep.
