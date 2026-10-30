# HRN-002: Container Consolidation

## Context

The platform consolidates tenant storage into containers. Tests must observe consolidation
as real state transitions over the live substrate.

## Acceptance

- **TC-CONTAINER-001** Consolidation merges tenant artifacts.
  - Given two tenants provisioned (HRN-001 helpers),
    When consolidation runs (real trigger over HTTP),
    Then `GET` of the consolidated container lists both tenants' artifacts, and the
    per-tenant pre-consolidation endpoints report moved/deprecated state.
- **TC-CONTAINER-002** Consolidation is idempotent.
  - Given a consolidated container,
    When consolidation is triggered a second time,
    Then the response is 200/204 with no duplicate artifacts (artifact list byte-equal
    before/after second run).

## Falsifier

A test asserting a consolidation "was requested" instead of asserting the merged artifact
list; or one that passes with the substrate down.

## Constraints

Chicago, mocks banned; loud SKIP exit 3. Tests at
`apps/api/src/containers.harness.test.ts`, helpers in `apps/api/src/testing/`.
