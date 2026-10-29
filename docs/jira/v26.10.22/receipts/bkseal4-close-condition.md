# BK-SEAL4 — seal close-condition run (v26.10.22)

- **Date**: 2026-10-22
- **Lane**: BK-SEAL4
- **Context**: solo (run on a shared, actively-edited checkout)
- **Standing**: **PARTIAL_ALIVE** — close condition NOT met: census reached 6/6
  mid-window, but no full `mix test` completed (3 attempts, 3 compile aborts,
  0 tests executed, each abort from a named in-flight lane file).

## BK-CENS4 wait (bounded)

Bounded poll ~10 min for `receipts/bkcens4-wave4.md`: **never appeared**.
No BK-CENS4 receipt exists on disk (nearest artifacts: `bkcens-census-registration.md`,
`bkcens2-registration2.md`). However, the census registration effect BK-CENS4
owns did land mid-window: the census went 2/6 → 6/6 between checks
(expl11r3/bkegs1 entries resolved), consistent with lanes registering their
own files without the receipt having been written yet.

## Embedded result lines (verbatim)

### Census — first run (~06:05, MIX_BUILD_ROOT=_build-bkseal4, fresh compile)

```
Result: 4/6 passed
Failed: 2 tests
```

### Census — immediate rerun (drifted further mid-window)

```
Result: 2/6 passed
Failed: 4 tests
```

Violations named ONLY in-flight lane files: `expl11r3_court_test.exs`
(forbidden JSON-decoder tokens), `bkegs1_fence_court_test.exs` (forbidden
`:httpc` tokens + off-allowlist module `Smalt.BKEGS1.FenceCourtTest`).

### Census — final check after registration landed

```
......
Finished in 0.5 seconds (0.5s async, 0.00s sync)

Result: 6 passed
```

### Full `mix test` — 3 attempts, all compile aborts (exit 1, 0 tests executed)

| run | abort file | evidence |
|---|---|---|
| 1 (~06:12) | `test/pipeline/fond_powl_runner_court_test.exs` — CompileError | owner edited it at 06:19 (7 min later) — active repair |
| 2 (~06:31) | `lib/smalt/egress_router.ex:4444` — missing closing delimiter | shared `lib/` frozen by an in-flight lane; cleared before run 3 |
| 3 (~06:40) | `test/internal/bkegs1_fence_court_test.exs` — CompileError | file mtime 06:40 = abort time — actively edited by its owner |

Protocol honored: bounded wait + one retry after run 1; runs 2-3 re-attempted
to capture the close-condition line after census went green, each classified
as compile-abort (exit 1, 0 tests), never as test failures.

## Gate stages (all green, verbatim tails)

```
[INVARIANT-GATES] PASS: 6/6 gates (positive held + all negative fixtures refused).
[SLEEP-GATE] PASS — 625 files, 0 unclassified sleep primitives
[PASS] sleep_gate_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
[PASS] sleep_gate court: clean PASSES, injected sleep REFUSED (…) restore byte-exact
kd-receipt-fence: checked 325 receipt cites across 6 registers + 2 pattern docs -> OK
docs-dod-check: OK (all receipt paths exist; kd-fence OK)
receipt-index: clean (committed index matches regeneration) — no regen needed
kd_flip read-only: FLIP-ELIGIBLE: 1 (KD-174, witness az1c-kafka-receipt.md); FLIP-PENDING-WITNESS: 1 (KD-168 registrar hold)
```

## Failure classification

Every full-suite abort is a **compile-freeze by an in-flight lane** (Class A,
compile-freeze SLA class): `fond_powl_runner_court_test.exs` (owning lane was
repairing it within the SLA window), `egress_router.ex` (shared `lib/` frozen
briefly; cleared), `bkegs1_fence_court_test.exs` (owner editing at abort
time). No test failure was observed anywhere (0 tests executed across 3
runs); no failure points at a defect in `lib/`. Census 6/6 at window close.

## Verdict

Seal close condition **unmet on this run**: census 6/6 reached, all gate
stages green, but no full-suite result line exists — the tree never stayed
compilable long enough. Honest standing: **PARTIAL_ALIVE**. Successor: rerun
the full suite on a quiescent tree (BK-SEAL5 or post-BK-EGS1 landing).
Successor should also witness a BK-CENS4 receipt landing
(`bkcens4-wave4.md` still absent as of 06:44).

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-bkseal4 mix test test/internal/internal_tier_census_test.exs
MIX_BUILD_ROOT=_build-bkseal4 mix test
python3 scripts/invariant_gates.py
python3 scripts/sleep_gate.py
bash scripts/shim_court/sleep_gate_court.sh
just docs-dod-check
python3 scripts/kd_flip.py            # read-only
python3 scripts/kd_receipt_fence.py
just receipt-index-check
```
