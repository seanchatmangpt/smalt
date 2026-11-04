# Module 04 Exercises

Answer in order; the solution key (`solution-key.md`) re-derives every number from
`data/kano-responses.csv` via `data/compute.py` (exit 0 required). Show derivations,
not just answers.

**E1.** In the Kano 3×3 evaluation table, name the cell that is (a) discarded as
information-free, (b) the "customer wants it absent" class, (c) the cell where a
functional answer of "like it" pairs with a dysfunctional answer of "can live with".
Give the class letter of each.

**E2.** A colleague proposes classifying attributes by "average of the functional scores
minus average of the dysfunctional scores". Give two reasons this is weaker than the
evaluation-table majority method used in the lab.

**E3.** From `kano-responses.csv`, tally K-05 (order-to-ship lead time) by hand into
Kano classes. Report counts per class, the majority class, SI, DSI, and whether the
SI/DSI pattern (high SI, strongly negative DSI) is consistent with a one-dimensional
attribute.

**E4.** K-09 (premium packaging) classifies I. K-10 (weekly quality trend report)
also classifies I, but the lab retains it as CR9. State the retention rule that
admits this exception and why K-09 fails it.

**E5.** A new respondent R13 answers (F=I, D=M) on K-02. Without recomputing
everything, state K-02's new tally, new majority, and whether the court would still
pass (n becomes 13; the court checks 12 rows per attribute — explain the consequence).

**E6.** Convert these paired ranks into ×100 integer points that sum to exactly 100
for 7 requirements (n=7): ranks CR-a=1, CR-b=3, CR-c=2, CR-d=5, CR-e=4, CR-f=7,
CR-g=6. Show the points formula and the sum check.

**E7.** (Court-authoring) Write a 4-line python check that would FAIL loudly if a
future edit to `gen_kano.py` moved K-10's majority off I. Why must the check read
the CSV rather than the generator's `KANO_ATTRS` dict?

**E8.** Forward-contract check: verify (from the lab Part D table) that the nine
×100 points {CR1..CR9} sum to 100, and name the downstream module and file that
consumes them as its importance column.

**E9.** Interview-guide audit: a teammate's guide asks "Would you pay more for a
dashboard?" as probe 4. Name two violations of the Slide-2 rules.

**E10.** A Kano response pair (F=A, D=A) appears 2× in K-03. State how the tally
handled it and what the Q-cell would have changed had it NOT been discarded (compute
the majority with and without discarding, from the CSV counts in the lab table).
