# ADR-001 — Petri protocol update (HAVE component 8)

- **Date**: 2026-10-18T21:33:36Z
- **Status**: PROPOSED (minted mechanically by `scripts/have/petri_conformance.py --mint-adr`)
- **Alert**: `ALRT-SEV1-PETRI-TOKEN-IMBALANCE`
- **Evidence log**: `../../../tmp/petri_protocol_update.ocel.json`

## Context

OCEL replay against net `scripts/have/petri_net.json` found event types in the
live log that the pinned settlement lifecycle does not declare:

```
OCEL log carries event type(s) queue.leak.reclaimed not declared in net 'rp04-canonical-settlement-lifecycle'; the settlement lifecycle changed and the net must be re-pinned
```

- `queue.leak.reclaimed`

## Decision

Re-pin `scripts/have/petri_net.json` to include the observed transition(s),
or extend the lifecycle spec and re-run conformance. The alert does not clear
until replay reports `conformant: true`.

## Consequences

- The net is the ground truth for settlement conformance; every protocol
  change must land as a net edit plus a receipted re-run.
- This ADR is minted only on PROTOCOL-UPDATE; REGRESSION quarantines instead.
