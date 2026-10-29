# EXPL12-D: servicebus residual flag drift — topic/subscription az shape + data-plane audit

Standing: ALIVE · Context: solo · 2026-10-22 · Lane EXPL12-D

Closes the residual SB drift from EXPL-12's tables after EXPL12-C's
queue-create repair (`expl12c-sb-name-flag.md`). Files touched:
`smalt-cli/smalt_cli/commands/servicebus.py`,
`smalt-cli/tests/test_ty_servicebus.py`.

## Finding (read-the-code-first)

The task premise ("topic/subscription create likely carry the same collision
shape as queue-create") was **wrong against the substrate**: no
topic-create/subscription-create commands existed at all in `servicebus.py`
— only `queue-create` + data-plane (`send`/`receive`/`peek-dead-letter`).
There was no collision to repair; the real divergence was a MISSING az
surface (`az servicebus topic create`, `az servicebus topic subscription
create` both exist in real az ~2.6x).

## Change

- **`servicebus topic-create` added**, built az-shaped from the start so the
  EXPL12-3 `-n` collision class never enters: `-n/--name` = TOPIC entity
  name (required), namespace on `--namespace-name` (az long form, primary;
  `--namespace`/`--ns` dual-spelling accepted per EXPL12-5 class), default
  `cli-ns`; `-g`, `-s`, `-o` as queue-create. ARM path
  `PUT .../namespaces/:ns/topics/:topic` (namespace PUT first, same
  idempotent shape as queue-create).
- **`servicebus subscription-create` added**, mirroring az
  `servicebus topic subscription create`: `-n/--name` = subscription entity
  name, `--topic-name` = parent topic (az long form), `--namespace-name`
  family as above. ARM path
  `PUT .../namespaces/:ns/topics/:topic/subscriptions/:sub`.
- Emit payloads: `{"topic", "namespace", "status"}` /
  `{"subscription", "topic", "namespace", "status"}`.

## Data-plane audit (typed, not renamed)

`send` / `receive` / `peek-dead-letter` remain honest emulator extensions —
real az has NO Service Bus data-plane CLI (confirmed again against az ~2.6x
conventions: nothing to rename TO). Spellings checked against az generic
conventions: `--output/-o` and `--subscription/-s` match az standards
(clean); `--max/-m` and `--wait/-w` have no az SB counterpart — typed
extension, left as-is. Zero renames; zero new collisions.

## Witness (real substrate, real wire)

`smalt-cli/.venv-cli/bin/python -m pytest tests/test_ty_servicebus.py -v
-p no:cacheprovider` (:enforce substrate, lane-private ports):

```
tests/test_ty_servicebus.py::test_queue_send_receive_roundtrip PASSED    [ 33%]
tests/test_ty_servicebus.py::test_queue_create_az_parity_short_n_is_entity_name PASSED [ 66%]
tests/test_ty_servicebus.py::test_topic_subscription_create_az_parity PASSED [100%]
============================== 3 passed in 32.00s ==============================
```

New az-parity leg `test_topic_subscription_create_az_parity`:
`topic-create -n ty-t-<uniq>` with NO `--namespace` (default `cli-ns`) ->
`"status": 201`; `subscription-create -n ty-s-<uniq> --topic-name ty-t-<uniq>`
-> `"status": 201`. Falsifier legs: neither `--help` surface carries
`--entity`, both carry `-n`/`--name`/`--namespace-name`. EXPL12-C's two legs
still pass unchanged (no regression to the queue repair).

Note: collection initially failed with `NameError: app` from
`smalt_cli/commands/login.py` — EXPL12-B's in-flight file (shared compile
freeze, not this lane's edit). Cleared by lane B within the SLA window; the
witness run above is fully green with no intervention from EXPL12-D.

## Residue

ty-t-/ty-s- topic/subscription resources under subscription `ty-sub` in the
emulator store, namespaced by the lane-unique UNIQ stamp. Emulator-local.
