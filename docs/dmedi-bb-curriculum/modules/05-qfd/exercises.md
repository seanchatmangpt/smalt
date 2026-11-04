# Module 05 Exercises

Every numeric answer must re-derive from `data/*.csv` via `python3 data/court.py`
(exit 0). Show derivations.

**E1.** Compute the technical importance of EC2 by hand from
`qfd-cppc-weights.csv` + `qfd-cppc-matrix.csv` (list each product term). Which CR
contributes most, and what does that say about whose voice EC2 really serves?

**E2.** Verify the conservation identity Σ(weighted rows) = Σ(column totals) = 1038.
Show both sums term by term.

**E3.** A teammate proposes adding EC7 "number of CNC machines on the line" with
relationships CR1=9, CR5=9. Give two reasons this violates the EC selection rules
taught in Slide 2, and state what the court would compute for the new column total.

**E4.** From `qfd-cppc-roof.csv`: (a) confirm the pair census is complete (15 of
C(6,2)); (b) list EC5's conflicts; (c) a design engineer responds to the EC1–EC5
"−−" by proposing to reach Cpk 1.33 via 100% final inspection instead of σ-reduction.
Argue why this fails the Slide-6 math (what happens to Cpk's σ term?).

**E5.** Show the Cpk arithmetic chain for EC1's target: tolerance ±0.008 mm, σ =
2.0 um, centered → Cpk. Then compute the σ that would be required if the internal
guard-band were tightened to ±0.005 mm at the same Cpk 1.33.

**E6.** The claims QFD uses direct-rating weights (22/20/7/15/13/23) while CPPC uses
paired-ranking (18/20/9/16/13/11/7/4/2). Recompute the claims weights as paired
ranks using the rating order (C6=1, C1=2, C2=3, C4=4, C5=5, C3=6; n=6, pool=21) and
report the new weights. Which CR gains most under the switch, and what does the
comparison teach about weight-method sensitivity?

**E7.** In the claims matrix, C6 (data security, w=23) has row sum 12 and T6 takes
column total 267 — the largest. A project lead concludes "T6 is the top transactional
priority, fund it first". Give one supporting fact and one caution from the roof
before that conclusion is admitted.

**E8.** Traceability: name (a) the Module 04 artifact each CR's Kano class comes
from, (b) the spine constant each of EC4/EC5 targets forwards to, (c) the module
that owns the Cpk 0.72 re-derivation flag, (d) the Lane 03 artifact the EC5 ceiling
$28.50 lands in.

**E9.** A CR row with all-blank cells enters the matrix. What does the conservation
identity still compute, and why is the row-sum check the only thing standing between
this and a silent omission at the gate?

**E10.** (Court-authoring) Add one check to `data/court.py` that fails loudly if a
future edit introduces a matrix cell value of 6 (a forbidden vocabulary item between
9/3/1 and blank). Explain why vocabulary restriction is checked, not "reasonable
values".
