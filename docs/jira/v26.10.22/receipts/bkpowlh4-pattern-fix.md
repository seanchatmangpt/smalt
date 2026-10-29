# BK-POWLH4 — BK-POWLH2-3 batch-drop repair: three self-exiting integration courts converted to ExUnit

Standing: ALIVE
Context: solo
Build root: `_build-bkpowlh4`
Date: 2026-10-22
Owner lane: BK-POWLH4 (repo /Users/sac/smalt)

## Verdict

BK-POWLH2-3 is closed. The three integration courts that both (a) failed Elixir
1.20's `test_pattern` (`*_test.exs`) and (b) self-exited the VM at script end
(`System.stop`/`System.halt` in a tail `case ... run() ... end` runner) are now
ExUnit cases. All court legs preserved verbatim; only the tail runner changed
(verdict asserted via `flunk/1` instead of halting the VM), plus the header
`Run:` comment line updated to the new `mix test` invocation.

## The three courts

| before (script, self-exits) | after (ExUnit, pattern-matching) | runner replaced |
|---|---|---|
| `test/integration/ath3_law_court.exs` | `test/integration/ath3_law_court_test.exs` | `case Ath3.Court.run() do :ok -> System.stop(0) ... end` → `Ath3LawCourtTest` asserting `== :ok` |
| `test/integration/gld7_ingest_to_settlement_court.exs` | `test/integration/gld7_ingest_to_settlement_court_test.exs` | `case Gld7.Court.run() ... System.stop` → `Gld7IngestToSettlementCourtTest` |
| `test/integration/graphlaw_dual_governance.exs` | `test/integration/graphlaw_dual_governance_test.exs` | `case Smalt.GraphLaw.DualGovernanceCourt.run() do 0 -> System.halt(0) ... end` → `GraphLawDualGovernanceTest` |

Selection evidence: `grep -L ExUnit test/integration/*.exs` finds 14 script
courts; exactly three of them carry a self-exit AND appear in BK-POWLH2-3's
named families (`ath3`, `gld7`, `graphlaw_*`). The remaining 11 script courts
and 24 other non-pattern ExUnit files are OUT OF SCOPE (no self-exit in a mixed
batch — they were never loaded at all under 1.20 `test_load_filters`, so they
cannot drop the batch) — registered here as out-of-scope residue, not silently
skipped.

## Embedded probe (before/after, _build-bkpowlh4)

```
# BEFORE (pre-edit baseline, `mix test test/integration`):
warning: the following files do not match any of the configured
`:test_load_filters` / `:test_ignore_filters`:   -> 39 files listed,
including ath3_law_court.exs, gld7_ingest_to_settlement_court.exs,
graphlaw_dual_governance.exs — none executed (batch result: 229 passed).
Run 1 same tree: 225/229, 4 failed (pre-existing flake, see below).

# AFTER (post-edit, `mix test test/integration`):
Result: 231/232 passed, Failed: 1   (232 = 229 + the 3 converted courts)
warning list -> 36 files; ath3/gld7/dual_governance ABSENT (grep exit 1).
In-batch verdicts, all PASS:
  COURT VERDICT: PASS (GL-6-dual-governance) — operational and analytical
  legs agree 9/9
  ATH-3 COURT: PASS
  GLD-7 COURT: PASS

# AFTER, individual invocations (each court at its new name):
mix test test/integration/graphlaw_dual_governance_test.exs \
  test/integration/ath3_law_court_test.exs   -> Result: 2 passed
mix test test/integration/gld7_ingest_to_settlement_court_test.exs -> 1 passed
```

## Census check

`test/internal/internal_tier_census_test.exs` and `scripts/acceptance_gates.py`
reference none of the three renamed paths (grep: zero hits) — no census edit
required. Nothing else outside docs/jira references the old paths outside this
milestone's receipts.

## Typed findings (not session-introduced; disclosed, not repaired here)

**BK-POWLH4-1 (pre-existing flake, pre-edit-witnessed):**
`test/integration/namespace_put_test.exs:106` `true = :code.delete(Smalt.EgressRouter.Peers)`
returns `false` when the module is not yet loaded in the VM — order/concurrency
dependent under the batch (failed once in the pre-edit baseline run 1 among 4
failures, passed standalone at 5/5 on rerun, failed once in the post-edit batch
run). Not touched by this lane (unowned file); the deterministic repair
(`:code.ensure_loaded/1` before delete) is registered for the owner lineage.

**BK-POWLH4-2 (compile-freeze witness, resolved during lane):** a transient
SyntaxError at `lib/smalt/messaging/amqp/connection.ex:3379` (another lane's
in-flight edit; file clean vs git at inspection) froze the shared compile for
one attempt; resolved by the owning lane within the SLA — rerun green. No edit
by this lane to any `lib/` file.

**Out-of-scope residue:** 36 integration files still do not match
`*_test.exs` (11 script courts + 25 other ExUnit misnamed files, count from
the after-run warning list). They are not loaded by batched `mix test
test/integration` — a separate hazard class (silent non-execution) from the
mid-batch drop BK-POWLH2-3 names; registered for a follow-up wave, not
repaired here.

## Repro commands

```
MIX_BUILD_ROOT=_build-bkpowlh4 mix test test/integration   # 232 tests, 3 courts pass in-batch
MIX_BUILD_ROOT=_build-bkpowlh4 mix test test/integration/ath3_law_court_test.exs \
  test/integration/graphlaw_dual_governance_test.exs test/integration/gld7_ingest_to_settlement_court_test.exs
```

## Files changed

- `test/integration/ath3_law_court_test.exs` (renamed from `ath3_law_court.exs` + tail runner conversion)
- `test/integration/gld7_ingest_to_settlement_court_test.exs` (renamed from `gld7_ingest_to_settlement_court.exs` + tail runner conversion)
- `test/integration/graphlaw_dual_governance_test.exs` (renamed from `graphlaw_dual_governance.exs` + tail runner conversion)
- `docs/jira/v26.10.22/receipts/bkpowlh4-pattern-fix.md` (this receipt)
