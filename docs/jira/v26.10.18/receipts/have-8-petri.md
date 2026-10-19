# HAVE component 8 — RP-04 Petri conformance over OCEL 2.0

**Standing**: ALIVE (all three verdict paths executed on real fixtures with real exits)
**Date**: 2026-10-18
**Subject**: `scripts/have/petri_conformance.py` @ main (uncommitted, per work order "no git")
**Authority**: HAVE component 8 work order (RP-04 formal conformance remediation)

## What landed

- `scripts/have/petri_conformance.py` — parses OCEL 2.0 JSON (exact
  `scripts/burn_to_ocel2.py` emitter shape: `ocel:eventTypes`, `ocel:objectTypes`,
  `ocel:events` with `id/type/time/attributes/relationships`, `ocel:objects`),
  replays events time-ordered against a Petri net transition table
  (`scripts/have/petri_net.json`, initial/final markings, per-transition input/output
  places), computes Tokens_consumed vs Tokens_produced per place, and emits typed
  `ALRT-SEV1-PETRI-TOKEN-IMBALANCE` rows naming the exact broken lifecycle link
  (producer transition -> consumer transition for the starved place).
- Classification: **REGRESSION** (net-known link broke; starved transition) ->
  `--quarantine` writes `tmp/have/quarantine/petri_<ts>.json`, exit 1.
  **PROTOCOL-UPDATE** (log carries event types the net does not declare) ->
  `--mint-adr` writes a decision record under `docs/jira/v26.10.18/decisions/`, exit 1.
- Net pins the RP-04 canonical settlement lifecycle:
  `arm.resource.transition -> amqp.delivery.settled -> blob.custody.transition`
  (places: `resources.unarmed -> delivery.pending -> delivery.settled -> custody.transfered`).
- Fixtures: `scripts/have/fixtures/settlement_complete.ocel.json` (3 events,
  conformant) and `scripts/have/fixtures/settlement_missing_settled.ocel.json`
  (deliberately missing `amqp.delivery.settled`).
- Exit contract: 0 conformant / 1 imbalance / 2 usage-IO error.

## Evidence — complete fixture (drift 0)

```
$ python3 scripts/have/petri_conformance.py scripts/have/fixtures/settlement_complete.ocel.json --quiet
COMPLETE_EXIT=0
$ python3 scripts/have/petri_conformance.py scripts/have/fixtures/settlement_complete.ocel.json
[PETRI] net=rp04-canonical-settlement-lifecycle events=3 fired=3 starved=0 unknown-types=0
[PETRI] place custody.transfered           produced=1 consumed=0 final=1 drift=0
[PETRI] place delivery.pending             produced=1 consumed=1 final=0 drift=0
[PETRI] place delivery.settled             produced=1 consumed=1 final=0 drift=0
[PETRI] place resources.unarmed            produced=0 consumed=1 final=0 drift=0
[PETRI] class=NONE conformant=TRUE reason=conformant
EXIT=0
```

## Evidence — broken fixture (missing `amqp.delivery.settled`): drift detected

```
$ python3 scripts/have/petri_conformance.py scripts/have/fixtures/settlement_missing_settled.ocel.json --quarantine
[PETRI] net=rp04-canonical-settlement-lifecycle events=2 fired=1 starved=1 unknown-types=0
[PETRI] place custody.transfered           produced=0 consumed=0 final=1 drift=-1
[PETRI] place delivery.pending             produced=1 consumed=0 final=0 drift=1
[PETRI] place delivery.settled             produced=0 consumed=0 final=0 drift=0
[PETRI] place resources.unarmed            produced=0 consumed=1 final=0 drift=0
[ALERT] ALRT-SEV1-PETRI-TOKEN-IMBALANCE {... "event": "ev-2", "transition": "blob.custody.transition", "missing_input_places": ["delivery.settled"], "broken_link": "place 'delivery.settled': produced by {amqp.delivery.settled} -> consumed by {NONE}; starved at event ev-2"} REGRESSION
[ALERT] ALRT-SEV1-PETRI-TOKEN-IMBALANCE {... "place": "custody.transfered", "drift": -1} REGRESSION
[ALERT] ALRT-SEV1-PETRI-TOKEN-IMBALANCE {... "place": "delivery.pending", "drift": 1} REGRESSION
[PETRI] class=REGRESSION conformant=FALSE reason=transition(s) blob.custody.transition starved: an upstream lifecycle link broke
EXIT=1
$ ls tmp/have/quarantine/
petri_20261018T213336.json
```

The alert names the exact broken lifecycle link: `amqp.delivery.settled` (producer of
`delivery.settled`) never fired before `blob.custody.transition` starved on it.

## Evidence — protocol-update path (unknown event type -> ADR minted)

```
$ python3 scripts/have/petri_conformance.py /tmp/petri_protocol_update.ocel.json --mint-adr
[PETRI] net=rp04-canonical-settlement-lifecycle events=3 fired=2 starved=0 unknown-types=1
[PETRI] place custody.transfered           produced=0 consumed=0 final=1 drift=-1
[PETRI] place delivery.pending             produced=1 consumed=1 final=0 drift=0
[PETRI] place delivery.settled             produced=1 consumed=0 final=0 drift=1
[PETRI] place resources.unarmed            produced=0 consumed=1 final=0 drift=0
[ALERT] ALRT-SEV1-PETRI-TOKEN-IMBALANCE {... "unknown_event_type": "queue.leak.reclaimed"} PROTOCOL-UPDATE
[PETRI] class=PROTOCOL-UPDATE conformant=FALSE reason=OCEL log carries event type(s) queue.leak.reclaimed not declared in net 'rp04-canonical-settlement-lifecycle'; the settlement lifecycle changed and the net must be re-pinned
[PETRI] minted decision record: /Users/sac/smalt/docs/jira/v26.10.18/decisions/ADR-001-petri-protocol-update.md
PROTO_EXIT=1
```

`ADR-001-petri-protocol-update.md` was minted by the validation run itself (mechanical
mint, not hand-written) and stands as the worked example of the protocol-update path.

## Replay

```bash
python3 scripts/have/petri_conformance.py scripts/have/fixtures/settlement_complete.ocel.json; echo $?          # 0
python3 scripts/have/petri_conformance.py scripts/have/fixtures/settlement_missing_settled.ocel.json --quarantine; echo $?  # 1
python3 scripts/have/petri_conformance.py <log-with-unknown-type> --mint-adr; echo $?                            # 1
```

## Falsifier

A conformance court that cannot fail is vacuous: the broken fixture IS the
non-vacuity proof — removing a single event flips exit 0 -> 1 with typed alert rows.

## Notes

- No git (per work order). Files: `scripts/have/petri_conformance.py`,
  `scripts/have/petri_net.json`, `scripts/have/fixtures/*.ocel.json`,
  `docs/jira/v26.10.18/decisions/ADR-001-petri-protocol-update.md`.
- Quarantine output reuses the existing `tmp/have/quarantine/` directory convention
  from earlier HAVE components (an uppercase `QUARANTINE` file path collided with a
  pre-existing directory; fixed to the lowercase dir).
