# BK-ETSFLK — ets_auto ON-leg restart-latency flake: slice-poll convergence

**Standing:** ALIVE
**Context:** solo
**Date:** 2026-10-22
**Lane:** BK-ETSFLK, `MIX_BUILD_ROOT=_build-bketsf`
**File owned:** `test/internal/ets_auto_court_test.exs` (only the poll form changed;
lib/ untouched)

## Defect (BK-CENS3 typed residual)

BK-CENS3 (`bkcens3-final-hop.md`) closed the ets_auto ArgumentError defect with a
converged-observable poll (restarted pid owns the table with target write_concurrency),
but kept a 15s one-shot bound. Under batch load that bound expired once (1 failure in the
35-test batch, non-deterministic set): the supervisor restart latency under load can exceed
any wall-clock guess.

## Fix — BK-FONDSD convergence law, same shape as the fond court's S3

`recreate_table!(:smalt_rolling_counters)`'s convergence check is now slice-polling
against a monotonic deadline: repeated `SmaltTest.Internal.Poll.eventually/2` slices
(250 ms slice budget, 250 ms pacing — all pacing inside the one audited poll
implementation; no new sleep site), with a 30 s cumulative monotonic deadline
(`slice_converge/3`); typed flunk on exhaustion. The assertion strength is UNCHANGED —
the converged observable is the same BK-CENS3 predicate (restarted pid ≠ old pid, owner
== pid, write_concurrency == target); only the wait shape changed from one-shot bound to
convergence-within-budget.

Note: while this lane ran, BK-ETSFIX's recycle-path change (Supervisor
terminate_child/restart_child instead of `GenServer.stop`, avoiding restart-intensity
give-up) landed in the same function — both edits are in the on-disk file; this lane's
diff is only the poll form. Mid-lane, 5 consecutive isolated runs were red
(`{:restarting, nil, old_pid}` — whereis nil for the full budget) while the sibling edit
was in flight; after it settled the same file runs green (the red was the in-flight
edit's intermediate state, not this poll). Both lanes' edits verified green together.

## Falsifier (embedded runs, this lane's build root)

Isolated `MIX_BUILD_ROOT=_build-bketsf mix test test/internal/ets_auto_court_test.exs`:

```
== run 1        == run 2        == run 3        == run 4        == run 5
Result: 3 passed Result: 3 passed Result: 3 passed Result: 3 passed Result: 3 passed
```

Post warning-fix (unused `pid` -> `_pid`) ×3: `Result: 3 passed` each, no warnings.

Loaded batch — `MIX_BUILD_ROOT=_build-bketsf mix test test/internal/`, 3 runs:

```
batch 1: Finished in 187.9 seconds — Result: 521/523 passed
batch 2: Finished in 225.6 seconds — Result: 522/523 passed
batch 3: Finished in 206.4 seconds — Result: 520/523 passed  (exit 2)
```

Zero ets_auto failures in all 3 batches. Remaining failures are sibling surfaces
(Smalt.ArmstrongIdiomCourtTest atom-count fence, InternalTier.Spof3AffidavitEngineCourtTest
SPOF-3.2, PPlan.ReceiptEngineTest 4-step run, VmZeroGrowth lazy singleton churn) — not
this lane's class.

## Falsifiers checked

- Slice poll passing on a stale state: impossible — the per-slice predicate is the same
  owner-identity + write_concurrency check BK-CENS3 pinned; slices can only EXTEND the
  wait, never loosen the predicate.
- New sleep site: none — grep of the test file shows `sleep` in comments only; pacing is
  `Process.sleep(min(poll_ms, remaining))` inside `SmaltTest.Internal.Poll` (the audited
  POLL-STEP implementation).

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"; cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-bketsf mix test test/internal/ets_auto_court_test.exs   # 3 passed
MIX_BUILD_ROOT=_build-bketsf mix test test/internal/                          # 0 ets_auto failures
```
