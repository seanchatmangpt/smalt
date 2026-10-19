# The Two-Green Court Law

Understanding-oriented. The law itself lives in the repo CLAUDE.md
(`just court-x2` — "two-green release receipt gate") and the wrap
sequence; this doc explains *why* one green is not enough and *why the
post-mortem is the evidence*.

## The law

A release gate runs the full admission court twice, back to back
(`just court-x2`, ~8 min). The gate is green only when both runs are
green AND the failure sets are identical-empty — i.e. both runs
fail-closed on any test failure, and a flake is detected by the
failure-set diff: two runs with the same failure count but different
failing tests is a RED verdict (`COURT_X2_RC=1`), not a pass. The
companion law on the single-run side: an invariant gate or a harness
that cannot exit 1 is the failure — admission must be able to refuse
(`gates/` negative fixtures; "a gate that can't exit 1 is the failure").

## Why two runs

One full-suite run is a sample of size one over a concurrent,
port-binding, ETS-heavy substrate. The second run exists to convert
three defect classes from invisible to typed:

1. **Port/boot contention** — run 1 boots the substrate, run 2 inherits
   residue. Witnessed: run 8's port-contention class
   (`docs/jira/v26.10.16/receipts/r216-court-x2-run8-red.md`).
2. **Flake family** — same failure count, different failing tests. The
   diff of failing test names is the alarm. Witnessed: run 12 was
   `1 failure` in both runs on *different* tests (a semantic-projection
   lens flake in one run, an affidavit seal flake in the other) —
   RED on the diff, correctly
   (`docs/jira/v26.10.16/receipts/r216-court-x2-run12-red.md`).
3. **Order/state coupling** — a test that passes alone and fails after
   its siblings; only a back-to-back pair over the same tree can see
   it, and the judge log distinguishes it from classes 1 and 2
   (`docs/jira/v26.10.16/receipts/r35-court-x2-judge-log.md`).

## Why the post-mortem is the evidence

A red gate is not a wasted run — it is the receipt of record for the
defect class. Each post-mortem receipt carries: standing (RED, both
runs' `COURT_X2_RC`), the signature (failure count per run), the typed
defect list (class, failing test, file:line), and the rule that no
fixes are applied by the court lane itself (typed defect list only, per
lane contract). That discipline is what makes the eventual two-green
receipt mean something: the green is green *against* the named red
classes, not green because the flaky tests were skipped or the court
was loosened. The wrap ledger's standing line ("flips only on the
two-green receipt", `docs/jira/v26.10.16/FINAL.md`) is the
organizational form of the same law.

## Fail-closed grading, not best-of-N

The gate never retries its way to green (no best-of-N; a third run to
"see if it goes away" would launder the flake). The flake is instead
filed to its family (e.g. `FLAKE_SOLO` family pins) and repaired at the
family level — the run-12 post-mortem names the family, not just the
instance. This is the same non-vacuity posture as the shim courts: a
court that cannot flip is FAIL, a skip is loud, and a pass that cannot
be reproduced twice is not yet a pass.

## See Also

- `docs/jira/v26.10.16/receipts/r216-court-x2-run8-red.md` — port
  contention class
- `docs/jira/v26.10.16/receipts/r216-court-x2-run12-red.md` —
  shifting-failure / flake alarm (the diff IS the detector)
- `docs/jira/v26.10.16/receipts/r35-court-x2-judge-log.md` — judge log
- `docs/explanation/emulation-stance.md` — the same loud-absence
  posture at the wire layer
- `docs/NO_SLEEP_DOCTRINE.md` — the same observe-not-wait law at the
  process level: courts read real state, never slept-for state
