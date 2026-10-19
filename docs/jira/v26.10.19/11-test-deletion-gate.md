# V261019-11 — Test-deletion gate: remove all 303 tracked test files + untracked bulk (clean-room reset)

> **Status at materialization (2026-10-19):** deletion LANDED at commit `64f6099`
> (303 tracked files removed; `git ls-files test/` == 1). The TS+PY+residual
> parity receipts at one pinned SHA are now a closing backfill, not a
> precondition — the WO's own receipt stays Standing UNKNOWN until they land.

- **Release:** v26.10.19
- **Lane:** test-deletion-gate
- **Base:** HEAD `4fd2ff2ba80e618341dc85de3ef84fcb8702bff3` — pre-deletion tree
- **Status:** draft — BLOCKED until preconditions below are witnessed PASS

## Objective

One-way-shaped but single-purpose **revertible** commit that deletes the
entire tracked test surface — `git ls-files test/ | wc -l` == 303 files at
the base HEAD — plus the untracked bulk (build trees, logs, venvs under
`test/`), re-grounds the repo on the residual tier only, and lands as ONE
commit whose sole purpose is deletion (so `git revert <sha>` restores the
world exactly).

## Preconditions (all must hold at the SAME HEAD sha, witnessed in the receipt)

1. `verification/ts/wf1..wf5` recorded PASS at HEAD sha X.
2. `verification/py/wf1..wf5` recorded PASS at the **same** HEAD sha X.
   (Both suites must be verified at one pinned tree — a ts PASS at sha X and
   a py PASS at sha Y != X is NOT a precondition satisfaction; the sha must
   be echoed in both receipts and must match.)
3. Residual tier (V261019-10) green at sha X: `mix test test/internal/`
   0 failures x2, so the post-deletion tree still has a live, green Elixir
   tier and the census guard is enforcing.

If any precondition is at a different sha: re-run the stale leg at the gate
sha before proceeding. No exceptions — the deletion is only justified by a
fully-verified tree.

## Execution

1. **Pin and echo:** `git rev-parse HEAD` → receipt. Refuse (exit non-zero)
   if the tree is dirty or HEAD != sha X.
2. **Tracked deletion:**
   ```bash
   git rm -r test/
   ```
   (303 files at base HEAD; re-count in the receipt — `git ls-files test/ |
   wc -l` before == files staged for deletion after).
3. **Untracked bulk:** remove untracked residue under `test/` only:
   ```bash
   git clean -xd test/
   ```
   (build trees, node_modules, `.venv-sb311`, `.logs` — everything `git
   clean -nxd test/` listed first; the dry-run list is pasted in the receipt
   BEFORE the real clean).
4. **Rebuild the minimal test surface:** keep/rebuild `test/test_helper.exs`
   and the five `test/internal/` files (from V261019-10) + any support file
   the residual tier needs. These are added in the SAME commit — the commit
   is deletion-of-old-surface + insertion-of-residual-tier, single-purpose
   and revertible as a unit.
5. **Budget reseed:** regenerate `docs/jira/v26.10.18/test_budgets.json`
   against the residual tier only (the deleted suites' budget rows are dead
   weight; reseed from a fresh `mix test test/internal/` so the budget gate
   judges the surviving tier, not ghosts). Ghost rows referencing deleted
   test names must be gone — the budget gate must not fail closed on
   missing entries that will never return.
6. **Recipe rewiring (loud no-ops):** every Justfile recipe that pointed at
   deleted test paths becomes a **loud `[RETIRED]` no-op** — prints
   `[RETIRED <recipe>] removed in V261019-11 (clean-room reset); see
   docs/jira/v26.10.19/` and exits non-zero (never exit 0 — a retired recipe
   that succeeds silently is a false-green). Recipes that still resolve
   (doctor, compile, census-over-surviving-tiers, court-x2 itself, sdk-*,
   bench) keep their bodies but drop the deleted-tier stages. `just court`
   is rewired to the residual surface; `just court-x2` still runs twice.
   Diff of the recipe rewiring pasted in the receipt.
7. **Single-purpose revertible commit:** one commit, message naming this WO,
   the preconditions' sha, and `git revert` instructions. No drive-by
   changes to `lib/`, `docs/` (beyond receipts/budget file), or CI config
   ride along.

## Post-deletion verification (all in the receipt, at the deletion HEAD)

1. `mix compile --warnings-as-errors` exit 0 (green).
2. **Dangling-ref census:** `grep -rn` over `Justfile`, `justfile.d/`,
   `scripts/`, `lib/`, `mix.exs`, `run_tests.exs`, CI configs for references
   to now-absent test paths/`test/` modules — 0 unresolved hits (each hit is
   either rewired or justified-line-commented). Includes
   `docs/jira/v26.10.18/test_budgets.json` (reseeded) and any
   `Code.require_file`/`test_helper` references to deleted modules.
3. Residual tier green at the deletion HEAD: `mix test test/internal/` x2.
4. `just doctor` exit 0.
5. `git status` clean after the commit; `git revert --no-commit <sha>` on a
   scratch worktree restores 303 files (revertibility witnessed once, then
   discarded — this check is read-only on a temp worktree).

## Close conditions

- Deletion commit exists, single-purpose, revertible; receipt at
  `docs/jira/v26.10.19/receipts/v11-deletion-gate.md` with: base sha,
  precondition shas (all equal), 303-file count witness, untracked
  dry-run list, budget-reseed diff, recipe-rewiring diff, dangling-ref
  census output, compile + residual-tier x2 evidence.
- Post: `mix compile` green; dangling-ref census 0; budget reseeded;
  recipes rewired loud; court-x2 capable of running on the residual surface
  (two greens witnessed by V261019-12, which this gate unblocks).
