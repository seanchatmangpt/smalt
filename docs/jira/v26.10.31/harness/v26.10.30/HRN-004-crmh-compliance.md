# HRN-004: CRMH Compliance

## Context

CRMH (court-record management hold) compliance requires holds to survive their full
lifecycle and expire on a 14-day lifecycle law.

## Acceptance

- **TC-CRMH-001** Hold lifecycle end to end.
  - Given a case (HRN-001), When a CRMH hold is placed, queried, and released via real
    HTTP,
    Then state transitions placed → active → released are each observed by subsequent GETs
    (final state per step, not call receipts).
- **TC-CRMH-002** 14-day lifecycle law.
  - Given a hold placed with `expires_at` unset,
    When the hold is created,
    Then the created hold's `expires_at` equals `created_at + 14 days` exactly (asserted on
    the returned entity — the platform computes the law, the test computes the same sum
    independently and compares).

## Faulifier

None recorded. (Typo-guard: the falsifier for this ticket: a test that accepts a hold
missing `expires_at`, or one that derives the 14-day sum from the server's own clock field
rather than computing it independently.)

## Constraints

Chicago; mocks banned; loud SKIP exit 3. Tests at
`apps/api/src/crmh.harness.test.ts`.
