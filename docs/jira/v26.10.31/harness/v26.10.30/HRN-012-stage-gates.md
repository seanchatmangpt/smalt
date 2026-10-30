# HRN-012: 3-Stage Gates (PRE -> LIVE -> POST)

## Context

The suite runs in three gated stages; each gate can exit nonzero and stop the line.

## Acceptance

- **PRE** (must all pass before LIVE):
  - doctor: substrate reachable on 127.0.0.1:9443 (health route) — unreachable => exit 3
    with typed reason.
  - ports: 9443 free of orphan holders (tree-aware orphan detection: a holder is an orphan
    only when its whole process tree has no listener).
  - pins: compat-pin.ttl present and fresh (SHA recorded at PRE, compared at POST for
    drift).
  - sts: smoke-mint one bearer token via the HRN-014 recipe — failure => exit 3.
- **LIVE**: all 7 domains run for real; no domain silently skipped — every domain reports
  pass/fail/SKIP(exit 3) with the TC ids executed.
- **POST**:
  - zero-drift: compat-pin.ttl SHA unchanged since PRE.
  - receipt ledger: JSON ledger of per-domain outcomes (pass/fail/skip) written to
    `receipts/` with subject SHA, timestamp, and TC-id rows.
  - purge: HRN-010 manifest purged; residual manifest => gate fails.

## Falsifier

A gate that cannot refuse: PRE passing with the substrate down, or POST passing with
residue.

## Constraints

Implemented as global setup/teardown in `apps/api/src/testing/harness-gates.ts`, wired via
the vitest globalSetup in HRN-014.
