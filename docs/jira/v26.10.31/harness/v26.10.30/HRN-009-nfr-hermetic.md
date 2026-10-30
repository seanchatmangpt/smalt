# HRN-009: NFR — Hermetic (offline isolation)

## Context

The suite must pass with no external network. Only 127.0.0.1 is reachable; anything else
is a defect.

## Acceptance

- The shared HTTP client (HRN-014) permits only `127.0.0.1` / `localhost` hosts; any other
  host fails the test with a typed hermeticity violation.
- No test reads external services, DNS-dependent hosts, or time-sync endpoints; STS token
  minting targets `{SMALT_ARM_ENDPOINT}` which must itself resolve to 127.0.0.1 (asserted
  at PRE).
- Grep gate: no test file contains external host literals (gate spec in HRN-015).

## Falsifier

A test that reaches an external host and still passes.

## Constraints

Chicago; mocks banned. Enforced in `apps/api/src/testing/client.ts` host allowlist.
