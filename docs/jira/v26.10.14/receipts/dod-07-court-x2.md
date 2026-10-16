# Receipt: DoD-07 — two-green-court receipt runner (court-x2)

- Repo: /Users/sac/smalt, branch main
- Date: 2026-10-15
- Owner: DoD-7 lane
- Standing: **PARTIAL_ALIVE** — runner built and exercised against real runs; two-green receipt NOT minted (flake-class failures witnessed)

## Built

- `scripts/court_x2.sh` (executable): runs `just court` twice consecutively,
  fresh runs, no reuse. Gate = both runs exit 0 AND both summary lines show
  `0 failures`. On failure prints failing test names from both runs and a
  diff of the two failure sets; a non-empty diff between run1/run2 failure
  sets is reported loudly as the shifting-failure / flake signature.
- `justfile.d/07-court-x2.just`: `court-x2` recipe with release-gate header
  comment (~8 min).

## Witnessed runs (all real output, /tmp/court_x2_witness{1,2,3,4}.log)

1. witness1: both runs FAIL at `doctor` — port 5672 held by PID 16561, an
   orphaned smalt substrate booted from this repo 12 min prior
   (`mix run ... amqp_port 5672`, cwd /Users/sac/smalt). Killed (session-owned,
   not a foreign holder). Same identical failure both runs — not a shift.
2. witness2: run 1 exit 2 — `test-offline`, 1898 tests, **1 failure**:
   `Smalt.SemanticProjectionTest "test domain read path over Store reads a
   seeded ledger receipt as a LedgerEntry"`. Run 2 never ran tests: justfile
   parse error (`ROOT` multiple definitions) from concurrent lane edits to
   `06-lane-cleanup.just` / `12-docs-dod.just`.
3. witness3: gate blocked by same parse error before any run.
4. witness4 (clean parse, fresh double run):
   - Run 1 exit 2 — `test-offline`: 1 doctest, 1898 tests, **1 failure**
     (`27 excluded`): `Smalt.DataPlane.CosmosTest "test list_docs continuation
     (version-2 token namespace) store restart drops the feed: post-restart
     resume is a typed 400, never a silent rescan"`.
   - Run 2 exit 2 — `test-offline` GREEN ("12 tests, 0 failures" tail from a
     member; summary line check: `0 failures — GREEN`), but `test-sdk-smoke`
     FATAL: substrate auth-mode drift — anonymous plane answered 400 (expect
     200), enforce plane 401. Printed remediation: kill listeners on
     9443/8443 and re-run. Ports verified free post-run.
   - Failure-set diff non-empty across runs → **shifting-failure / flake
     signature DETECTED and reported by the runner**, exactly the class this
     session's wave targeted.

## Isolation re-runs (real output)

- `mix test test/semantic_projection_test.exs` → 21 tests, 0 failures.
- `mix test test/data_plane/cosmos_test.exs` → 105 tests, 0 failures.

Both failures pass in isolation ⇒ flake-class (test-isolation/lifecycle),
not mechanical. Per DoD brief: NOT fixed; reported and stopped.

## Disclosed cross-lane unblock fixes (compile-freeze SLA)

- `justfile.d/06-lane-cleanup.just`: recipe lines 20+ had extra leading
  whitespace (just parse error) — de-indented to exactly 4 spaces; shell
  semantics unchanged. Later rewritten wholesale by lane 06.
- `justfile.d/12-docs-dod.just`: renamed `ROOT` → `DOCS_ROOT` (2 lines) to
  resolve `ROOT :=` collision with lane 06; parse verified exit 0.

## Falsifier / remaining block

Two-green receipt unreachable while the offline tier carries a
flaky-per-full-court-run test (a different one each wave: SemanticProjection,
then Cosmos list_docs continuation). Next move: test-isolation repair on the
Cosmos store-restart test, then re-run `just court-x2` for the receipt.
No commits made.
