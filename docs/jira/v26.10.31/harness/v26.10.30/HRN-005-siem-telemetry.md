# HRN-005: SIEM Telemetry

## Context

Security-relevant events must surface as real telemetry observable by the harness.

## Acceptance

- **TC-SIEM-001** Auth events emit telemetry.
  - Given a live substrate, When an unauthorized request (TC-TENANT-003 class) is issued,
    Then the SIEM endpoint/pipe receives the corresponding auth-failure event with the
    request's correlation id.
- **TC-SIEM-002** Telemetry shape.
  - Given any emitted event, When read back,
    Then it carries `timestamp`, `event_type`, `correlation_id`, `source` — asserted on the
    event entity itself.

## Falsifier

A test that asserts a log line "was written" without reading the telemetry entity back; or
one passing with the substrate down.

## Constraints

Chicago; mocks banned (no fake SIEM sink); loud SKIP exit 3. Tests at
`apps/api/src/siem.harness.test.ts`.
