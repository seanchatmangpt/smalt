# WO v26.10.15 / 25 — Flake quarantine with receipt-verified promotion

- **Repo:** /Users/sac/smalt
- **Witnessed failure designed against:** court-x2 could NOT mint its
  two-green receipt (dod-07: standing PARTIAL_ALIVE, "flake-class failures
  witnessed") — run 1 died on a single test-isolation-class failure
  (`Smalt.SemanticProjectionTest` ledger-receipt read) that passes in
  isolation; fin-22 confirms isolation re-runs were 105/0 cosmos,
  21/0 semantic-projection. The 07-cosmos receipt itself records the same
  class: restart-court poll was lengthened 500x10ms -> 2000x50ms for a CI
  flake. One flake blocks the release gate; the gate cannot distinguish
  "regression" from "known nondeterminism under concurrency".

## 1. Problem

The repo's only flake tools today are (a) re-run and hope (court-x2's
failure-set diff reports the shift loudly but blocks anyway), and (b) manual
poll-lengthening (cosmos restart court). There is no typed way to say "this
test is known-nondeterministic, has a named hypothesis, and a fix in
flight" — so one flake kills court-x2, or worse, a flake silently re-runs
green and the underlying nondeterminism is never owned.

## 2. Move

A `:quarantine` ExUnit tag + receipt-verified promotion ladder:

1. **Tag:** `@tag :quarantine` (with metadata, see below). `test_helper.exs`
   adds `quarantine: :exclude`... specifically the default court run
   excludes quarantined tests; `mix test --include quarantine` runs them.
   This matches the repo's existing named-exception discipline
   (`test_helper.exs` already default-excludes `:amqp_wire` with documented
   owners — quarantine rows reuse exactly that law, documented in
   `docs/TEST_ISOLATION.md`).
2. **Quarantine record** (module attribute or a registry file
   `test/support/quarantine_registry.exs`): each quarantined test needs
   **all three**:
   - the N consecutive isolated greens (default N=3, `mix test <file>:<line>`
     runs),
   - a **named nondeterminism hypothesis** (e.g. "shared-tree Store ETS
     teardown race under concurrent mix test" — the semantic-projection
     class), and
   - the fix (landing WO or receipt reference), not "will investigate".
3. **Promotion:** fix lands; N consecutive isolated greens + green in the
   default court run -> tag removed, registry row closed with receipt. If N
   greens can't be produced, the quarantine was wrong (either the test is
   actually broken, or the hypothesis is wrong) and it is demoted to a KD /
   GAP row, not left parked.
4. **Abuse guard — quarantine is not a graveyard:** `just quarantine-report`
   lists every quarantined test with **dwell time** (days in quarantine),
   hypothesis, fix reference, and greens count; rows dwelling past **2
   windows** escalate (printed as BLOCKING in court output and doctor.py
   check). No row may be re-quarantined for the same hypothesis twice.
5. court-x2 integration: run 1 flake-class failures that match an active
   quarantine row are re-run in isolation by court_x2.sh automatically
   (instead of failing the gate); a failure NOT matching any row still
   blocks.

## 3. Falsifier

- **F1:** a deliberately quarantined test is NOT excluded from the default
  court run (tag/registry wiring broken) — quarantine leaks failures back
  into the gate.
- **F2:** a quarantined test with <N isolated greens gets promoted (the
  promotion ladder is decorative — registry state can be flipped without
  receipt evidence).
- **F3:** `just quarantine-report` lists a row dwelling >2 windows without
  escalation firing (doctor/court output stays green) — the graveyard guard
  is decorative too.

## 4. Acceptance

1. Exclusion witness: default `just court` (or `mix test`) skips the
   quarantined test; `--include quarantine` runs it; F1 exercised with a
   throwaway tag.
2. Promotion witness: registry row with N=3 receipt-linked greens promotes
   and un-tags; a row with 2/3 greens refuses promotion (typed error).
3. Escalation witness: a row aged past 2 windows shows BLOCKING in
   `quarantine-report` and doctor.py flags it; court-x2 gate stays red
   until the row resolves.
4. court-x2 auto-isolated-rerun path exercised: a flake matching an active
   row does not mint a red gate; a non-row failure still blocks (dod-07's
   shifting-failure diff still fires for non-row failures).
5. `docs/TEST_ISOLATION.md` quarantine section + registry live; dod-07's
   witnessed flake class (semantic-projection) re-triaged under the new
   ladder and either quarantined-with-fix or fixed.

## 5. Files owned

- `test/test_helper.exs` (add `quarantine: :exclude` to the ExUnit.configure
  exclude list, beside `:amqp_wire`)
- `test/support/quarantine_registry.exs` (new — rows: test id, hypothesis,
  fix ref, greens ledger, quarantined_at)
- `scripts/court_x2.sh` (auto isolated-rerun for row-matching flakes;
  escalation printing)
- `justfile.d/07-court-x2.just` (`quarantine-report` recipe)
- `scripts/doctor.py` (dwell-time check)
- `docs/TEST_ISOLATION.md` (quarantine law section)
- Receipt `docs/jira/v26.10.15/receipts/25-flake-quarantine.md` with F1-F3
