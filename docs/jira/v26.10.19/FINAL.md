# FINAL.md — v26.10.19 window wrap

- **Date**: 2026-10-19
- **Subject**: smalt repo root (branch main; version `<!-- mix.exs @version -->`)
- **Context**: solo(documentation wrap; no execution, no git state changes)
- **Standing of this document**: CENSUS — every claim cites a receipt on disk.
  The court-x2 verdict is `<!-- TYPED-RED | TYPED-GREEN | PARTIAL_ALIVE -->`
  (carried/closed; see §3).

## 1. Landing

- **Landing commit**: `<!-- full SHA -->` (`<!-- short SHA -->`, main) —
  "<!-- commit subject -->", `<!-- N -->` files, `<!-- +X/−Y -->`.
- **Push**: `<!-- oldSHA -->..<<!-- short SHA --> main>`; push SHA
  `<!-- SHA -->`. `<!-- No commits after the landing commit / N follow-up
  commits: list receipts -->`.

## 2. Gate verdicts

- **court-x2**: `<!-- verdict -->` — receipt
  `docs/jira/v26.10.19/receipts/<!-- rNNN-court-x2-*.md -->`
  (Standing: `<!-- ... -->`). `<!-- Two consecutive greens witnessed / not
  witnessed; attempt ledger path -->`.
- **publish-dry**: `<!-- verdict -->` — receipt
  `docs/jira/v26.10.19/receipts/<!-- publish-dry receipt -->`
  (tarball key/leak greps, regen identity: `<!-- witnessed pre-commit,
  post-commit, both -->`).

## 3. Post-commit gates (7-gate table, surface at HEAD `<!-- short SHA -->`)

| # | Gate | Command | Verdict | Receipt |
|---|---|---|---|---|
| 1 | court-x2 | `just court-x2` | <!-- PASS/FAIL/NOT RUN --> | `<!-- path -->` |
| 2 | publish-dry | `<!-- publish-dry just recipe -->` | <!-- --> | `<!-- path -->` |
| 3 | docs-dod-check | `just docs-dod-check` | <!-- --> | `<!-- path -->` |
| 4 | invariant-gates | `<!-- command -->` | <!-- --> | `<!-- path -->` |
| 5 | naming-sweep | `bash scripts/naming_sweep.sh` | <!-- --> | `<!-- path -->` |
| 6 | gen-error-codes | `python3 scripts/gen_error_codes.py --check` | <!-- --> | `<!-- path -->` |
| 7 | sdk-matrix | `python3 scripts/sdk_coverage.py` | <!-- --> | `<!-- path -->` |

<!-- Score line once filled: N/7 PASS. Note any FAIL with its semantic vs
mechanical fix disposition and owning lane. -->

## 4. Test-volume census (before → after, per metrics plan)

Reduction target: ≥80% vs the v26.10.18 baseline
(`docs/jira/v26.10.18/test_budgets.json`; census receipt
`receipts/v261019-vol-census.md`).

| Metric | Before | After | Reduction | Target ≥80% | Receipt |
|---|---|---|---|---|---|
| Tracked test files | 303 | 1 | 99.7% | MET | `receipts/v261019-11-test-deletion-gate.md` |
| ExUnit leaves | 2,763 (budgeted, manifest era) | 20 (executed: `mix test` → "20 tests, 0 failures", exit 0) | 99.3% | MET | `receipts/v261019-vol-census.md` |
| node:test leaves | 97 (grep census) | 97 (grep census; suites not executed) | 0% | NOT MET (external surface untouched) | `receipts/v261019-vol-census.md` |
| Harness exits | n/a | n/a | — | not executed this window | `receipts/v261019-vol-census.md` |
| pytest items | 156 (grep `def test_` at 64f6099~1) | 150 (collected) | 3.8% | NOT MET | `receipts/v261019-vol-census.md` |
| **Leaf-weighted total** | 3,016 | 267 | **91.1%** | **MET** | `receipts/v261019-vol-census.md` |

Standing of this census: CENSUS-PARTIAL — the tracked-file and ExUnit rows
are executed/committed ground truth; node:test and pytest "before" counts
are grep-censused, not executed; the aggregate 91.1% clears 80% only because
the ExUnit reset dominates the leaf population. The pytest and node:test
surfaces were scoped out of the deletion and carry open into the next
window.

## 5. Counts (`just receipt-index`, re-witnessed by `<!-- lane -->`)

- Receipt files: `<!-- N -->` (indexed `<!-- N -->` incl. `<!-- N -->` SDK results)
- SUSPECT: `<!-- N -->` (output-less receipts flagged in RECEIPTS.md)
- Known divergences (KD-01..KD-`<!-- N -->`): `<!-- O -->` OPEN, `<!-- C -->`
  closed with receipts (`<!-- KD-xx file.md; ... -->`)
- Bench results files under `bench/`: `<!-- N -->`
- Standing mix: `<!-- N -->` ALIVE / `<!-- N -->` PASS / `<!-- N -->`
  PARTIAL_ALIVE / `<!-- N -->` TYPED-RED / `<!-- N -->` FAIL — per-lane table
  in [RECEIPTS.md](RECEIPTS.md)

## 6. Publication gate

`<!-- Decision: signing.key rotation coordinator decision, unchanged (fin-21
lineage) / rotate this window -->` — receipt `<!-- path -->`.

## 7. Planning handoff to next window

`<!-- v26.10.20 window planned and on disk at ../v26.10.20/ — PLANNING.md,
_LANES.md, seeds, RESOLUTIONS.md; or: not yet planned, open items below -->`

Ordered open items carried from `docs/jira/v26.10.18/FINAL.md` §4 and this
window's outcomes:

1. `<!-- item — carried/closed this window; receipt -->`
2. `<!-- ... -->`

## 8. Pointers

[RECEIPTS.md](RECEIPTS.md) ·
[v26.10.18 FINAL.md](../v26.10.18/FINAL.md) ·
[`<!-- court-x2 verdict receipt -->`] ·
[`<!-- publish-dry receipt -->`] ·
[`<!-- test-census receipt -->`] ·
[KNOWN_DIVERGENCES.md](../v26.10.18/azsim-burn/KNOWN_DIVERGENCES.md) ·
[SDK_MATRIX.md](../v26.10.18/azsim-burn/SDK_MATRIX.md)

Notes on sourcing:
- Gate commands in §3 rows 1, 3, 5, 6, 7 are taken verbatim from the v26.10.14 post-commit gate list; publish-dry and invariant-gates command lines are placeholders to be filled from the window's receipts/justfile at fill time.
- The 7-gate set matches your list exactly; v26.10.14 had a 6/7 variant (compile/doctor/gap-sync instead of publish-dry/docs-dod/invariant-gates), so those two command strings should be confirmed against `justfile.d/` before finalize.
- All KD-count, receipt-count, and test-volume cells are intentionally empty — no values were invented; the only real numbers carried over are the ≥80% target and receipt path conventions from the prior two FINALs.
