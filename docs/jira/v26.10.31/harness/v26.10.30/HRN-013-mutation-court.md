# HRN-013: Mutation Court (>90% kill)

## Context

Tests are proven non-vacuous by mutation: reverting/inverting the behavior under test must
flip the assertions to red.

## Acceptance

- Court protocol per domain: BASELINE (suite green on real substrate) -> MUTATE (invert one
  behavior: e.g. invert a response header value, corrupt a request input, flip a status
  code) -> AFTER (suite must go red on the mutated subject) -> RESTORE (byte-exact restore,
  sha256-verified).
- Coverage: every TC id in HRN-001..007 maps to at least one mutation class
  (inverted headers, corrupted inputs, flipped status codes, wrong api-version, wrong
  expires_at law).
- Kill rate > 90%: a surviving mutant = suite stays green on the mutated subject; >10%
  survivors => court FAIL (exit 1). A mutation class that cannot flip the suite is itself
  a FAIL, never a skip-quiet.

## Falsifier

A court that cannot flip — any mutation class that leaves the suite green — is itself a
FAIL, not a pass.

## Constraints

Chicago: mutations are applied to a real temp copy with real restore, never faked. Court
runner spec at `apps/api/src/testing/mutation-court.ts` (HRN-014 wires the npm script).
