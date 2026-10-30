# HRN-015: Definition of Done — KPIs as Gates

## Context

The charter KPIs are executable gates, not prose.

## Acceptance

- **Suite < 45 s**: timed gate — full harness-family suite wall time recorded in the POST
  receipt ledger; >= 45 s => gate fails.
- **Mock count = 0**: grep gate over test dirs with a non-vacuity check: the gate asserts
  it scanned > 0 test files before asserting 0 matches for
  `vi\.mock|jest\.mock|unittest\.mock|mockall|sinon`; any match or empty scan => exit 1.
- **Flake = 0**: 1000-loop job spec — CI lane runs the harness family 1000 consecutive
  iterations, one fresh process per loop (HRN-010 purge makes loops independent); any
  non-SKIP failure => gate fails. Nightly lane; the PR gate runs a 10-loop smoke.
- **Mutation kill > 90%**: HRN-013 court result recorded in the receipt ledger; < 90% =>
  exit 1.
- **Loud SKIP**: every SKIP line carries a typed reason; substrate-down => exit 3 enforced
  by the HRN-014 client.

## Falsifier

A DoD gate that cannot fail: e.g. the grep gate matching nothing because the glob is wrong
(closed by the non-vacuity check).

## Constraints

Gate script at `scripts/harness-dod-gate.sh` (or justfile recipes); receipt ledger under
`receipts/` (directory exists at repo root).
