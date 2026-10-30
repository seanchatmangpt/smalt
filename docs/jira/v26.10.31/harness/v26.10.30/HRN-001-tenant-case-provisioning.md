# HRN-001: Tenant-Case Provisioning

## Context

Provisioning a tenant and its cases is the platform's entry transition. The harness must
provision real tenants through real HTTP to `127.0.0.1:9443` and assert on resulting state,
never on call counts.

## Acceptance

- **TC-TENANT-001** Provision tenant.
  - Given a live substrate on 127.0.0.1:9443 and a valid bearer token,
    When `POST /api/tenants` with a unique-per-loop tenant name,
    Then 201 with a tenant id; a subsequent `GET` on that id returns the same name and
    state `active` (final state asserted, not the POST response alone).
- **TC-TENANT-002** Provision case under tenant.
  - Given the tenant from TC-TENANT-001,
    When `POST /api/tenants/{id}/cases`,
    Then 201; `GET` of the case returns `tenant_id` equal to the parent tenant id and a
    case id usable in later domains.
- **TC-TENANT-003** Unauthorized provisioning refused.
  - Given no bearer token (or expired token),
    When `POST /api/tenants`,
    Then 401 with a typed error body; no tenant is created (list unchanged after).

## Falsifier

A test that passes while the substrate is down (must exit 3 instead), or that asserts on a
stubbed router rather than the live HTTP response.

## Constraints

Chicago: real HTTP, mocks banned. Bearer via STS (HRN-014 recipe). Loud SKIP exit 3 when
substrate down. Tests live at `apps/api/src/testing/` helpers + suite file
`apps/api/src/tenants.harness.test.ts`.
