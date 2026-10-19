# Receipt — V261019-12 (court-x2-close)

Context: solo(V261019-12) — no court-x2 execution this session.
Standing: **NOT-RUN** — `just court-x2` was not executed by this lane or
recorded as executed by any lane receipt in this window; the close remains
pending. Per the no-overclaiming law, no close is claimed.
Base: 64f6099663a4ec32fd9478c4c39fca49ab1961f8 (shared checkout, 143 dirty paths)
Date: 2026-10-19

## What changed

- Nothing landed for this WO. The `just court-x2` gate
  ("two consecutive fresh greens; shifted failures = flake signature")
  requires a quiesced tree (`just quiet-check` precondition per the
  receipt-context law) and two consecutive fresh runs at one SHA. The tree
  is actively in-flight this window (143 dirty paths; the residual tier's
  6 files are untracked; the ts/py suites are unlanded) — a court-x2 run
  now would not be a close.
- Prior-window evidence that the gate still exists and can exit 1 honestly:
  `tmp/court-x2-v17-run1.log` exists in `tmp/` from a prior window's run
  (scratch, not indexed); the v26.10.17 window closed on attempt 3
  (`docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md`).

## Verification (real output tails)

```
$ just court-x2     # NOT EXECUTED — no output exists; do not cite a run
```

Not executed. Preconditions not met: (a) unlanded suites and untracked
residual tier would make any green non-closeable; (b) no quiet-window
precondition was established this session.

```
$ git rev-parse HEAD
64f6099663a4ec32fd9478c4c39fca49ab1961f8
```

(Recorded as the base any future pair of runs must hold fixed.)

## Acceptance greps

- `grep -c "court-x2" docs/jira/v26.10.19/receipts/v261019-12-court-x2-close.md`
  => counted mentions only, zero executed-gate blocks — consistent with
  NOT-RUN standing.
- No prior court receipts superseded by this close (none exists).

## Deviations

1. Skeleton placeholders anticipated a close; reality is a pending gate.
   Standing NOT-RUN, flip-gated on two fresh green runs at one SHA after
   the suites land.
