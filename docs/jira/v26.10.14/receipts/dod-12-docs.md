# DoD-12 Receipt — Documentation Definition-of-Done

- Date: 2026-10-15
- Lane: DoD-12 (docs truth-sync, /Users/sac/smalt)
- Files owned: `justfile.d/12-docs-dod.just`, `README.md` (root),
  `docs/DEV_LOOP.md`, `CHANGELOG.md`, this receipt.
- Base: `main` @ 3fc2543 (uncommitted v26.10.14 fan-out tree). No commits
  made (per lane contract).

## Deliverables

1. `justfile.d/12-docs-dod.just` — `just docs-dod-check`: verifies every
   receipt/surface path named in README/DEV_LOOP/CHANGELOG exists on disk.
   Real run: 9/9 OK, exit 0 (verified via `just --justfile
   justfile.d/12-docs-dod.just docs-dod-check`).
2. `README.md` — new "Workspaces & Tooling" section (~15 lines) describing
   `workspace/`, `smalt-cli/`, `test/sdk-{full,smoke,python}`, and
   `test/enclave-testbed/` with their entry points. Only recipes that exist
   are named as commands; not-yet-landed recipes (`cli-gates`, an enclave
   just recipe) are explicitly named as pending with their owning lane.
3. `docs/DEV_LOOP.md` — new "Workspace / SDK / release tooling recipes"
   table adding the same recipes to the dev loop (ws-*, test-sdk-smoke,
   census, enclave run.sh, run_gates.py, publish-dry, court-x2,
   docs-dod-check).
4. `CHANGELOG.md` — four factual one-liners under `[Unreleased]`, one per
   landed lane family (workspace, smalt-cli, enclave testbed, SDK courts),
   each receipt-linked. The enclave testbed line states factually "No lane
   receipt yet" (grep over `docs/jira/v26.10.14/receipts/*.md` finds zero
   mentions of enclave — verified, not assumed).

## Truth-sync spot-checks (claim -> receipt, all verified on disk)

1. "ws-01..ws-11 receipts exist" -> `ls docs/jira/v26.10.14/receipts/`:
   ws-01-scaffold .. ws-11-compliance all present. OK.
2. "four-gate verification runner" -> `receipts/cli-08-gates.md` documents
   GATE1-4 (`gates.py`, `run_gates.py`, AU-10 ledger). OK.
3. "census SKIP-loud without SMALT_SDK_ROOT" ->
   `receipts/12-gate-closure.md` lines 12/31-32 witness the SKIP semantics
   and a real `env -u SMALT_SDK_ROOT just census` SKIP run. OK.

## Not claimed (DoD-only)

- No capability claims beyond receipts: no "all gates green", no enclave
  PASS claim (its README describes the harness; no receipt pins a run).
- `KNOWN_DIVERGENCES.md` (DoD-10) had not landed at write time; tolerated
  per lane contract.
- Known friction fixed in-lane: just 1.56 shebang recipes error on
  `$(justfile_directory())` in the body (syntax error at that line); the
  recipe uses `ROOT := parent_directory(justfile_directory())` +
  `{{ROOT}}` interpolation instead (same pattern as 06-lane-cleanup.just).
