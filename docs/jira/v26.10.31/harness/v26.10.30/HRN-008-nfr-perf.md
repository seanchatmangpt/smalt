# HRN-008: NFR — Performance (15 ms loopback ceiling)

## Context

Loopback HTTP round-trips must stay within 15 ms per request — a ratio-fenced ceiling
validated against the substrate's own health-probe baseline, not a sleep-hedged guess.

## Acceptance

- Per-request loopback latency (connect -> response end) is measured for every harness
  request via `perf_hooks` timing hooks in the shared client.
- Ceiling: 15 ms per request, p100 over the suite (any request over ceiling fails the
  suite's perf gate).
- Fence is relative: the ceiling is validated against the substrate's own health-probe
  baseline measured in PRE; if the baseline itself exceeds 15 ms, the suite exits 3
  (substrate misconfigured, not a code failure) — never a silent pass.

## Falsifier

A perf gate that passes with no timing recorded, or a fixed sleep used in place of
measurement.

## Constraints

Chicago; measurement is real (Node `perf_hooks`); mocks banned. Perf check in
`apps/api/src/testing/latency.ts` + assertions wired into the HRN-014 shared client.
