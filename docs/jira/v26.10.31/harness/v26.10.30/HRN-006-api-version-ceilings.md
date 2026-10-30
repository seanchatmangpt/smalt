# HRN-006: API Version Ceilings

## Context

api-version query parameters are ceiling-pinned by `compat-pin.ttl` (harness-supplied
input; not present in this repo today). Tests must never send an api-version above the
pin.

## Acceptance

- **TC-VER-001** Pinned versions only.
  - Given compat-pin.ttl declares ceiling C for a route family,
    When the harness issues requests to that family,
    Then every `api-version` on the wire is <= C (asserted by re-reading the pin file at
    test time and comparing against the actual query string sent).
- **TC-VER-002** Above-ceiling refusal.
  - Given ceiling C, When a request with api-version = C+1 is sent,
    Then the substrate refuses with a typed error (asserted per family).

## Falsifier

A test that hardcodes an api-version instead of reading compat-pin.ttl.

## Constraints

Chicago; mocks banned; loud SKIP exit 3. Pin source: `compat-pin.ttl` (path resolved at
PRE stage per HRN-012; fail loudly if absent). Tests at
`apps/api/src/versioning.harness.test.ts`.
