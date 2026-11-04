# Module 29 — Solution Key (README §4 lab exercises)

Conceptual module: no dataset. Every number below is arithmetic derived with
python3 -c one-liners (exit 0, 2026-11-04); commands cited inline. Re-run,
do not trust.

## Exercise 1 — classification

- "uncoated" → LEVEL (of the factor tool coating).
- "one housing machined at 9000 RPM + 300 mm/min" → RUN (one experimental unit
  receiving one level combination).
- "Ra" → RESPONSE (the measured surface-finish output).
- "Tuesday morning" → BLOCK (a homogeneous time group / nuisance factor).

## Exercise 2 — shop-floor audit

Graded on structure, not a fixed answer. Full credit requires: (i) the tested
term named (e.g. randomization violated by sequencing all low-speed runs
first), (ii) the consequence stated in CPPC terms (confounding with tool wear),
(iii) the cheapest fix named (re-randomize run order; costs nothing but
discipline). Any of the ten terms in README §2 is a lawful target except
"design matrix" (a plan artifact, not a discipline that can be violated at run
time).

## Exercise 3 — run count and error df for a blocked 2^4 x 3

python3 receipt: `python3 -c "print(2**4*3, 2**4*3 - 2**4 - 1)"` → exit 0.

- Runs = 2^4 x 3 replicates = 16 x 3 = 48.
- Total df = 48 − 1 = 47. Subtract the block df (2 blocks → 1) and the
  factorial-treatment df (2^4 − 1 = 15): error df = 47 − 1 − 15 = **31**.

Derivation shown: each replicate of the 16 corners contributes 16
observations; the 15 orthogonal effect contrasts each consume 1 df; the block
contrast consumes 1; what remains (48 − 16 − 1 = 31) is pure error.

## Exercise 4 — repeated-measurement trap

python3 receipt:
`python3 -c "print((0.5/7.407)**2, 1/(0.5/7.407)**2)"` → exit 0 →
0.004557 and 219.45.

The fake "error" MS is the gauge variance (mean of squared deviations among 3
sub-measures of one housing ~ gauge sd^2 = 0.25); the true error MS is the
process variance (7.407^2 = 54.86). Ratio = 0.25 / 54.86 = 0.00456 ~ 1/219 —
the README's "roughly 1/220". Consequence: the fake error term is ~220x too
small, so every F test using it inflates by ~220x — false positives on
genuinely null factors, exactly the README §2 "experimental unit" violation.

## See also

README §4 (the exercises), Module 30 keys/data (the worked numeric sibling).
