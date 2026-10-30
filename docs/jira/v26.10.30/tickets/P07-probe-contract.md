# P07 — Liveness/readiness probe contract as a gating precondition

- window: v26.10.30 · id: CLM-07 · receipt: folded into r-p08-harness.md

## Claim

The probe surface answers the documented health shape before any scenario
runs, and the harness hard-fails (typed exit 2) if it never comes up — no
wait-and-hope.

## Falsifier

Tests starting against non-ready pods, or a probe accepted on shape deviation.
