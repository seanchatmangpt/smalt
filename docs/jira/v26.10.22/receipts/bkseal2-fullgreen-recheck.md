# BK-SEAL2 — full-green recheck after BK-CENS

- **Date**: 2026-10-22
- **Lane**: BK-SEAL2
- **Context**: solo (run on a shared, actively-edited checkout; see classification)
- **Standing**: **PARTIAL_ALIVE** — seal precondition NOT met; failures remain, classified below.

## Summary

BK-CENS (3d5aa9e9) cleared the three census-fence blockers from
`bkseal-full-green.md`, and that much is confirmed: the four formerly-blocked
files pass the census **when it runs against a quiescent tree**. But the tree
moved again mid-recheck: 4 NEW in-flight lane files
(`expl9r1_egress_guard_court_test.exs`, `expl9r2_arm_guard_court_test.exs`,
`mcpt1_dispatch_court_test.exs`, `kd169r_cred_gate_test.exs`) are present,
unregistered, and re-drift the population fence. The seal is chasing a moving
target.

## Embedded result lines (verbatim)

### Stage 1 — census standalone (quiescent moment, 04:57)

```
......
Finished in 0.1 seconds (0.1s async, 0.00s sync)

Result: 6 passed
```

6/6 green — **BK-CENS blockers confirmed cleared at that moment**.

### Stage 2 — full `mix test` (first completed run)

```
Finished in 260.1 seconds (2.6s async, 257.4s sync)

Result: 735/739 passed
Failed: 4 tests
```

### Stage 2 — full `mix test` (second completed run, after two in-flight compile aborts cleared)

```
Finished in 264.1 seconds (2.2s async, 261.8s sync)

Result: 764/780 passed
Failed: 16 tests
```

## Failure classification (second run, 16 failures)

### Class A — in-flight census drift (5 failures, in-flight-owned)

`InternalTier.CensusTest`: population fence, status-literal, ARM-literal,
module-allowlist, forbidden-client-token — all violated ONLY by the 4
unregistered in-flight files above (violation lists name them exclusively).
Identical failure class to what BK-CENS already fixed for
bkamqpf/eplaw/kd173r. Owner: the lanes authoring those 4 files must register
them (typed exemptions where lawful) or land them; until then every full
`suite` run fails the census by construction.

### Class B — cross-lane contention (11 failures, contention, not real defects)

Evidence pattern: another lane's `mix test` overlapped ours.

- `Smalt.ClusterTest` (2): `net_kernel` name `smalt_clu_main@127.0.0.1`
  "seems to be in use by another Erlang node" — only possible with a
  concurrent BEAM running the same suite.
- `Powl2PrimitivesTest` (6): `:ets.new(:powl8_sb_rules, ...)` →
  `:already_exists` (named table owned by the overlapping run's process);
  one `{:tcp_closed, ...}` last-message flake.
- `EventGridWebhookTest` (1): `start_supervised!` →
  `{:already_started, #PID<0.5622.0>}` — singleton already up from the
  overlapping run.
- `Spof3AffidavitEngineCourtTest` (1): busy-observation race under load.
- `T27lqListQueuesFeedTest` (1): the queues feed contained
  `q-expl9r2-small-15747` / `kd51-props-*` entities created by concurrent
  lanes' tests — shared-store contamination.

None of these assert a broken behavior in `lib/`; each is a duplicate-runtime
collision artifact. Not independently re-proven green in this session (a
quiescent rerun would be needed), hence PARTIAL_ALIVE, not a claim of a fully
healthy suite.

### Compile-freeze incidents during the run (disclosure)

- Run 2 aborted: `lib/smalt/attestation/maa.ex` compile error (transient,
  self-cleared).
- Run 3 aborted: `test/internal/expl9r1_egress_guard_court_test.exs`
  mismatched delimiter, broken >6 min (past the ~10 min SLA window, within
  it at flip time — the owning lane repaired it themselves; I read the file
  to prepare a minimal unblock fix and found it already fixed. **No edit
  applied by this lane.**).
- Run 1 and run 4 completed; runs 2-3 were compile-abort (exit-1, 0 tests),
  correctly distinguishable from test failures.

## Stages 3-6 recheck (verbatim tails)

```
[INVARIANT-GATES] PASS: 6/6 gates (positive held + all negative fixtures refused).
[SLEEP-GATE] PASS — 616 files, 0 unclassified sleep primitives
kd-receipt-fence: checked 311 receipt cites across 6 registers -> OK
```

- docs-dod-check: OK (all receipt paths exist; kd-fence OK).
- receipt-index: regenerated RECEIPTS.md/INDEX.md for v26.10.20/21/22
  (artifacts, not staged by this lane).

## Verdict

Seal precondition remains **unmet**: 0-failure full suite not achieved, but
every observed failure is attributable to (a) census registration drift from
4 named in-flight files, or (b) cross-lane test-runtime collisions. No
failure points at a defect in `lib/`. The seal should be re-run on a quiescent
tree (or with in-flight lanes' files registered) — likely `just quiesce` +
rerun, per the v26.10.17 quiet-check law.

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"
MIX_BUILD_ROOT=_build-bkseal2 mix test test/internal/internal_tier_census_test.exs   # 6 passed
MIX_BUILD_ROOT=_build-bkseal2 mix test                                               # 764/780, 16 failures (classified)
just invariant-gates && just sleep-gate && just docs-dod-check && just receipt-index
```
