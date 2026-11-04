# Module 16 — Concept Selection: Pugh and AHP

Course spine: CascadeProjects Precision Components (CPPC). Read
`../../RUNNING-CASE.md` first. Pinned constants, including the ADJUDICATED
2026-11-04 baseline (bore sigma = 7.407 um, Cpk = 0.72), apply without
variation.

## Where this sits in DMEDI

Module 13 generated and scored a concept portfolio; Module 14/15 enriched it
with TRIZ. This module is the **selection gate of Develop**: two structured
selection methods — Pugh matrix and AHP — applied to the SAME four-concept
bore-finish problem, so students see where the methods agree and, more
importantly, where they diverge and why.

## Learning objectives

By the end of this module you can:

1. Construct a Pugh matrix with a JUSTIFIED datum (the incumbent citizen
   regrind route, pinned to the baseline Cpk 0.72) and criteria traceable to
   the QFD engineering characteristics of module 05.
2. Assign S/+/-/0 marks with a STATED scoring basis per cell and defend each
   mark from pilot data (`data/concept_trials.csv`) or route facts.
3. Compute tallies, run a consolidation iteration (Pugh convergence: never
   choose on raw net alone when a tie or dominance relation exists), and
   carry a strengthened hybrid concept forward.
4. Build an AHP model on the same problem: criteria pairwise matrix, Saaty
   scale, principal-eigenvector weights, lambda_max, consistency ratio
   (CR < 0.10), per-criterion concept matrices grounded in the pilot data,
   and global scores.
5. Diagnose an intentionally inconsistent matrix by its lambda_max inflation
   (lambda_max = 7.616 > n = 5, CR = 0.584) and repair it.
6. Explain WHY unweighted Pugh and weighted AHP can pick different iteration-1
   winners, and resolve the divergence lawfully (tie escalated to data +
   weights, not vote-trading).

## Timing (90 minutes)

| segment | minutes |
|---|---|
| Slides: method mechanics, datum justification, Saaty scale, CR | 20 |
| Lab: Pugh matrix + consolidation iteration | 25 |
| Lab: AHP on the same four concepts | 25 |
| Agreement/divergence debrief + exercises kickoff | 10 |
| Exercise setup, Q&A | 10 |

Prerequisites: modules 05 (QFD engineering characteristics), 12 (capability),
13 (concept portfolio).

## Tool note

Everything in this module runs on **python3 only** (stdlib `csv`, `math`).
No Minitab, Excel, or third-party packages are required. AHP is computed with
the principal-eigenvector method via a 200-iteration power method and
cross-checked against the geometric-mean method; both derivations are shown
in `solution-key.md`. Students without python3 can complete the Pugh half by
hand and the AHP half with the worked matrices in the solution key.

## Files

| file | purpose |
|---|---|
| `data/concept_trials.csv` | 4 x 30 pilot trials, seed 1607 |
| `scripts/gen_trials.py` | dataset generator (byte-reproducible) |
| `scripts/derive_selection.py` | derivation engine; exit 0 = all court checks pass |
| `slides-outline.md` | slide-by-slide outline |
| `lab.md` | 50-minute guided lab |
| `exercises.md` | 8 exercises |
| `solution-key.md` | full python3-derived derivations |
| `court.md` | court record: every derivation exit-checked |
| `data/court-run.txt` | captured court output (exit 0, 21 checks PASS) |
