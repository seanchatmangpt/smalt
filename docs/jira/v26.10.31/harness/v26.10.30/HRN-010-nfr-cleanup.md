# HRN-010: NFR — Cleanup (state determinism, 0 residue)

## Context

Every loop of the suite must start from an equivalent world. Provisioned entities are
tracked and purged.

## Acceptance

- Every created entity (tenant, case, hold, secret) is registered in a manifest at
  creation time.
- `afterAll`/POST stage purges every manifest entry via real HTTP DELETE; purge success is
  asserted (final state: entity gone or the typed deleted-or-echo outcome per HRN-003).
- A determinism probe: run the suite's provisioning block twice in one process; the second
  run must succeed identically (no unique-constraint collisions from residue).

## Falsifier

A suite that leaves entities behind yet passes; a purge asserted by response code only
without a follow-up read.

## Constraints

Chicago; mocks banned. Manifest + purge helpers at
`apps/api/src/testing/manifest.ts`.
