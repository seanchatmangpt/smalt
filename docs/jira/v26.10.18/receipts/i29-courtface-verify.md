# i29 — courtface-harden premise verification (solo-green ×3 ×2 files)

- Context: slice
- Standing: PASS (solo-green baseline confirmed on current uncommitted state)
- Date: 2026-10-19

## Subject

Current uncommitted state of the two courtface-harden touched files:

- `test/azsim/topology_test.exs` — carries BOTH faces:
  - ARM-PUT wire emission (TopologyTest:141 area, "ARM resource PUT emits
    ResourceWriteSuccess to integration plane")
  - identity-plane STS-over-wire (`mint_over_wire/1` helper, lines ~243+:
    real-socket POST `/organizations/oauth2/v2.0/token`, hardened with a
    bounded `SmaltTest.AssertEventually.eventually/2` poll on StsGate
    whereis + wire-mint 200 — no sleep; typed flunk with last observed
    status on timeout)
- `test/wire/arm_wire_test.exs` — ARM wire emission surface

The harden lane's edits ARE present in `test/azsim/topology_test.exs`
(AssertEventually poll with the "court-x2 run-2 face" comment) — not
[IN-FLIGHT].

## Evidence (scripts/fast_test.sh, private per-hash roots)

```
=== topology_test.exs ===
run 1: 8 tests, 0 failures  (wall: 3s,  _build-ft-be19d7a1)
run 2: 8 tests, 0 failures  (wall: 1s,  _build-ft-be19d7a1)
run 3: 8 tests, 0 failures  (wall: 1s,  _build-ft-be19d7a1)

=== arm_wire_test.exs ===
run 1: 6 tests, 0 failures  (wall: 3s,  _build-ft-39c9c2dc)
run 2: 6 tests, 0 failures  (wall: 2s,  _build-ft-39c9c2dc)
run 3: 6 tests, 0 failures  (wall: 2s,  _build-ft-39c9c2dc)
```

## Verdict

6/6 runs green. Baseline: 3/3 topology, 3/3 arm_wire — exceeds the
solo-green floor (3/3, 3/3). Zero errors, zero skips observed. No edits
made, no git operations.
