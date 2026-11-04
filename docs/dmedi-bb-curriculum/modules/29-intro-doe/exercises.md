# Module 29 Exercises — Introduction to DOE (Terminology Discipline)

Source: README §4 (four lab exercises). No dataset — every number below is
stdlib arithmetic; receipt: `python3 -c` one-liners, exit 0 (see
`keys/solution-key.md` for the exact commands and receipts). Re-run, do not trust.

**Time: 35 min** (Ex 1: 5 min, Ex 2: 15 min, Ex 3: 10 min, Ex 4: 5 min).

## Exercise 1 — Classify the artifacts (5 min)

Classify each as factor / level / run / response / block:

1. "uncoated"
2. "one housing machined at 9000 RPM + 300 mm/min"
3. "Ra"
4. "Tuesday morning"

### Key (derivation shown)

1. **LEVEL** — one setting of the factor *tool coating*.
2. **RUN** — one experimental unit receiving one level combination.
3. **RESPONSE** — the measured surface-finish output (CTQ).
4. **BLOCK** — a homogeneous time group (nuisance factor to be subtracted or
   randomized away).

## Exercise 2 — Shop-floor audit (15 min)

Audit a real (or reconstructed) shop-floor "test": name which of the ten terms
in README §2 it violates, the consequence in CPPC terms, and the cheapest fix.

### Key (grading rubric, not a fixed answer)

Full credit requires all three: (i) the tested term named (e.g. randomization
violated by sequencing all low-speed runs first), (ii) the consequence stated in
CPPC terms (speed contrast confounded with monotone tool wear → study scrapped),
(iii) the cheapest fix named (re-randomize run order; costs nothing but
discipline). Any of the ten terms is a lawful target except **design matrix**
(a plan artifact — it cannot be violated at run time).

## Exercise 3 — Run count and error df for a blocked 2^4 × 3 (10 min)

Compute the run count for a 2^4 factorial with 3 replicates and one blocked
factor (2 blocks). How many df for error?

### Key (derivation shown)

Receipt: `python3 -c "print(2**4*3, 2**4*3 - 2**4 - 1)"` → exit 0.

- Runs = 16 × 3 = **48**.
- Total df = 47. Subtract the block contrast (2 blocks → 1 df) and the 15
  factorial-effect contrasts (2^4 − 1): error df = 47 − 1 − 15 = **31**.

Equivalent count-up: 48 − 16 (replicate-internal error carries the remaining
31 = 48 − 16 − 1) — each orthogonal effect contrast consumes exactly 1 df, and
what survives the 15 effects + 1 block is pure error.

## Exercise 4 — The repeated-measurement trap (5 min)

Gauge sd = 0.5 um, process sd = 7.407 um. Three sub-measures of one housing are
counted as n = 3. What is the ratio of the fake "error" MS to the true error MS?

### Key (derivation shown)

Receipt: `python3 -c "print((0.5/7.407)**2, 1/(0.5/7.407)**2)"` → exit 0 →
0.004557 and 219.45.

The fake error MS is the gauge variance (0.25); the true error MS is the process
variance (54.86). Ratio = 0.25 / 54.86 = **0.00456 ≈ 1/219** — the fake error
term is ~220x too small, so every F test built on it inflates by ~220x: false
positives on genuinely null factors. This is README §2's "experimental unit"
violation; Module 30 buys real replicates (2 per corner, SSE on 8 df) precisely
to avoid it.
