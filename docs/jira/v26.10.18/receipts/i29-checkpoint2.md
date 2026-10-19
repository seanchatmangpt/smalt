# i29 — Checkpoint 2 (post-Context-law remediation census)

Date: 2026-10-18.
Context: solo(/Users/sac/smalt).
Standing: ALIVE — census + index hygiene; no lib/test edits, git read-only (no add/commit — coordinator owns git).
Subject: /Users/sac/smalt @ main, HEAD `f56ee6b` working tree.

## 1. Receipt-index refresh (`just receipt-index`)

- totals: receipts=587 sdk=51 total=638, suspects=17 (16 pre-existing in v26.10.14/16/17 windows + 1 new in v26.10.18).
- v26.10.18 before remediation: **8 NO-CONTEXT** receipt rows + 1 SUSPECT.
- Root cause: receipts carried `Context:` as `- Context:` bullets or `- **Context**:` bold — `receipt_index.py` matches only `^Context:\s*(solo|pair\(|slice\(|full)`. All 9 flagged receipts (8 + `i29-stress-fresh2.md` which landed mid-run) had the line normalized to line-start `Context:` form per `docs/jira/v26.10.17/RECEIPT_CONTEXT_LAW.md`.
- After regen: v26.10.18 NO-CONTEXT = **0**. No receipt content/output was altered — line placement only.
- Remaining v26.10.18 SUSPECT: `i29-docker-reclaim.md` (standing UNKNOWN, no embedded command output). Pre-existing; left untouched (output cannot be fabricated).
- `just docs-dod-check`: exit **0** (all receipt paths named in docs exist).

## 2. git status --porcelain census, grouped by owning in-flight lane (HEAD f56ee6b)

### Landed-receipt-backed (diff has a receipt naming it)

| file | owning lane / receipt |
|---|---|
| `docker/burn/compose.burn.yml`, `docker/burn/parallel-matrix.sh` | AZB-17 burn lane; `azb-17-parallel-matrix.md` (PARTIAL_ALIVE — 1x4 salvage probe, jsonl `burn/parallel-matrix-1x4-1792388155.jsonl` rides the same commit) |
| `docs/jira/v26.10.16/sdk-results/spc-bands.md` | bench-runner lane; `i29-bench-check.md` (n 281→287 SPC reband) |
| `.ggen_igniter/manifest.json`, `.ggen_igniter/receipts/2026-10-19.jsonl` | pack lane; `i29-pack-lock-repin.md` (committed a8e8867); manifest + receipts jsonl are the repin's generated ledger residue — rides next commit |
| `docs/jira/v26.10.18/receipts/{azb-17-parallel-matrix,i29-court-rehearsal,i29-fence-hammer,i29-pack-lock-repin,i29-plane-sup-flake-fix,i29-push-readiness,i29-sleep-budget-gates,i29-stress-fresh2}.md` | THIS lane (Context-line normalization per RECEIPT_CONTEXT_LAW); content unchanged, placement only |
| `docs/jira/v26.10.18/RECEIPTS.md`, `docs/jira/v26.10.18/receipts/INDEX.md`, `docs/jira/v26.10.14/RECEIPTS.md`, `v26.10.14/receipts/INDEX.md` | THIS lane — `just receipt-index` regenerated artifacts |

### In-flight (no closing receipt on disk yet)

| file | state |
|---|---|
| `docs/jira/v26.10.18/test_budgets.json` | 4,576-line reseed diff; mtime fresh this window. `i29-budget-verify.md` (untracked) documents the PRE-reseed FAIL (772 unmanifested / 61 stale, exit 1) and explicitly disclaims the reseed ("I did not re-seed"). **No reseed receipt on disk** → budget-reseed lane still in-flight; do not commit the manifest without its receipt |
| `scripts/doctor_dod.py` | GAP-token census modernization (retires lane-13 5+9 census for live-open register, adds 5 retired-token notes + `GAP(blob-x-ms-date-unvalidated)`); **no receipt on disk names this edit** → in-flight, owner must file before commit |
| `package.json`, `package-lock.json` (root), `test/sdk-smoke/package.json` + `package-lock.json` | node/npm probe surface; only `azb-08-identity-plane.md` mentions npm in passing, **no receipt names these files** → in-flight, no receipt yet |

### Concurrent-lane noise during this census

Receipts landed while census ran (coordinator commits `84268de`, `a8e8867`, `0e5797c`, `f56ee6b` landed mid-run); ARG-lane files (`test_helper.exs`, `TEST_ISOLATION.md`, `sovereign_midnight_test.exs`) were committed at `f56ee6b` before this receipt was written — moved to landed in the census above.

## 3. Proposed next commit boundary (coordinator)

1. **Commit now (index hygiene, self-contained)**: the 8 Context-normalized receipts + the 4 regenerated RECEIPTS.md/INDEX.md — `docs(jira): Context-line normalization per RECEIPT_CONTEXT_LAW + receipt-index regen`.
2. **Commit now (AZB-17)**: `docker/burn/*` + `burn/parallel-matrix-1x4-1792388155.jsonl` + `azb-17-parallel-matrix.md` — receipt landed (PARTIAL_ALIVE, salvage probe).
3. **Hold**: `test_budgets.json` until the reseed lane files its receipt (`i29-budget-verify.md` is a verification of the pre-state, not the reseed receipt).
4. **Hold**: `scripts/doctor_dod.py` until its owner files a receipt (GAP-token census retirement is a register-adjacent change, receipt-gated).
5. **Hold**: root `package.json`/`package-lock.json` and `test/sdk-smoke/package.*` until a receipt names them (possible leak check needed — untracked manifest files at repo root are a tarball-leak grep candidate for `publish-dry`).
6. **Commit with pack lane**: `.ggen_igniter/manifest.json` + `.ggen_igniter/receipts/2026-10- flag` → `.ggen_igniter/receipts/2026-10-19.jsonl` residue with the next pack-lane commit.
7. Untracked receipts (`i29-budget-verify.md`, `i29-full-soak-c.md`, `i29-replay-fences.md`, `i29-sdk-census-fresh.md`, `i29-stress-fresh2.md`) ride their owning lanes' commits; run `just receipt-index` again at wrap.
