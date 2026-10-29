# EXPL12-C: servicebus `-n` flag collision repaired (EXPL12-3)

Standing: ALIVE · Context: solo · 2026-10-22 · Lane EXPL12-C

Repairs EXPL12-3 from `docs/jira/v26.10.22/receipts/expl12-cli-flag-parity.md`
(P1: servicebus `-n` short flag = `--namespace`, colliding with az's
`-n` = `--name` muscle memory, plus POS queue name). Files touched:
`smalt-cli/smalt_cli/commands/servicebus.py`,
`smalt-cli/tests/test_ty_servicebus.py`. EXPL12-R's storage/deployment work
untouched; EXPL12-B login/profile work has NOT landed (no receipt), so the
namespace default stays the literal `cli-ns`.

## Change

`servicebus queue-create` is now az-shaped:

- `-n/--name` = the queue (entity) name — required option, replaces the
  old positional `queue` argument. Real az: `az servicebus queue create
  -n <queue> --namespace-name <ns> -g <rg>`.
- Namespace moved OFF `-n` onto `--namespace-name` (az long form, primary)
  with `--namespace`/`--ns` still accepted (EXPL12-5 dual-spelling class);
  default `cli-ns`.
- Data-plane commands (`send`, `receive`, `peek-dead-letter`) are emulator
  extensions (az has no SB data-plane CLI) and keep their POS queue
  argument — the collision was a control-plane-only shape.
- Emit payload keys unchanged (`queue`/`namespace`/`status`).

## Falsifier (embedded, real)

The old collision shape is gone from help and code paths:

- `grep -n "entity" servicebus.py` matches only docstring prose
  ("materializes the AMQP entity") — zero `--entity` flags anywhere in the
  command group.
- In-suite falsifier legs in
  `test_queue_create_az_parity_short_n_is_entity_name`: positional queue
  name now REFUSES (nonzero exit), `--help` carries `-n`, `--name`,
  `--namespace-name` and no `--entity`.

## Witness (real substrate, real wire)

`smalt-cli/.venv-cli/bin/python -m pytest tests/test_ty_servicebus.py -v
-p no:cacheprovider` (:enforce substrate, lane-private ports):

```
tests/test_ty_servicebus.py::test_queue_send_receive_roundtrip PASSED    [ 50%]
tests/test_ty_servicebus.py::test_queue_create_az_parity_short_n_is_entity_name PASSED [100%]
============================== 2 passed in 40.78s ==============================
```

The az-parity leg runs `queue-create -n ty-azq-<uniq>` with NO `--namespace`
(namespace default `cli-ns`) -> `"status": 201` on the wire, then proves the
entity materialized by sending real AMQP traffic over :5672
(`"transport": "amqp:5672"`). The roundtrip leg proves `--namespace`
dual-spelling still routes to the same ARM path.

## Residue

ty-rg-ty-q/ty-azq namespace/queue resources under subscription `ty-sub` in the
emulator store, namespaced by the lane-unique UNIQ stamp. Emulator-local.
