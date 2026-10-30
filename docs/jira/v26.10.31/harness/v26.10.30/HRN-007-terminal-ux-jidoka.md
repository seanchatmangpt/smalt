# HRN-007: Terminal UX Jidoka

## Context

Terminal harness output follows jidoka: failures stop the line loudly; progress is
observable; no silent continuation after a defect surfaces.

## Acceptance

- **TC-UX-001** Failure stops the line.
  - Given a domain test fails, When the harness reports,
    Then the run exits nonzero, the failure names the TC id, substrate address, and typed
    reason; no subsequent stage auto-continues past a PRE failure.
- **TC-UX-002** Progress observability.
  - Given a running suite, When each domain starts/ends,
    Then the runner prints per-domain start/end with pass/fail/skip counts; a SKIP line
    always carries the typed reason and corresponds to exit 3 semantics.

## Falsifier

A harness that continues to LIVE after a failed PRE stage, or prints a bare SKIP with no
reason.

## Constraints

Runner-level behavior; implemented in the HRN-014 runner config plus a reporter module.
Tests at `apps/api/src/testing/reporter.test.ts`.
