# Court-x2 DRY-RUN leg 4 — full `mix test` at HEAD f4f129f

- **Date**: 2026-10-18
- **Subject**: /Users/sac/smalt @ `f4f129f2a73f0edf5c57f88b11d987ebe21891c9` (≥ f4f129f)
- **Command**: `MIX_BUILD_ROOT=_build-ft-court4 mix test` (cwd /Users/sac/smalt)
Context: solo(2 runs, same build root `_build-ft-court4`)

## Runs

| run | wall | summary |
|---|---|---|
| 1 | 239.1 s | `1 doctest, 7 properties, 2733 tests, 0 failures, 1 invalid (99 excluded)` |
| 2 | 202.8 s | `1 doctest, 7 properties, 2733 tests, 0 failures (99 excluded)` — fully green, no invalid |

Run 1 output was tailed only (no full log); the invalid test's identity was not
captured. Run 2 captured a full log (/tmp/court-dry4-run2.log): zero failures,
zero invalid.

## Failure classification (strict)

| Class | Observed |
|---|---|
| DetsRecovery rotating (F-class) | 0 |
| EventGrid/egress 503 readiness (F58/F60) | 0 |
| GracefulStop boot (F59) | 0 |
| Topology cross-test (F61) | 0 |
| boot-contention (:eaddrinuse / already-started / setup_all timeout) | 1 invalid (run 1, identity uncaptured in-lane) |
| **Non-LOAD** | **0** |

The run-1 invalid matches the face already classified in
`receipts/i29-wire-fresh2.md`: `Smalt.Chaos.CrashIsolationTest` setup_all
`eventually("ARM listener answering")` timeout — LOAD/boot-contention class.
Run 2 did not reproduce it (no invalid, no failures), consistent with a
transient boot-contention face, not a deterministic defect. The in-flight
working-tree edits (atom_bridge + amqp test files, sovereign_midnight,
wire tier refusal sweep) compiled clean and passed both runs. No compile abort.

## Acceptance

**ACCEPTED — zero NEW.** Both runs zero failures; the sole non-green token
(run 1's `1 invalid`) is the known LOAD-class CrashIsolationTest setup_all
face, absent in run 2. No edits, no git ops, no `_build` deletion
(`_build-ft-court4` preserved for replay).

## Standing

PASS (solo; run 2 fully green of 2733 with no invalid; run 1 zero failures
with 1 known-LOAD-class invalid, identity uncaptured post-hoc — disclosed as-is).
