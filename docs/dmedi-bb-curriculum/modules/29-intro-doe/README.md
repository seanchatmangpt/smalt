# Module 29 — Introduction to Design of Experiments

## Learning objectives

After this module the candidate can:

1. Define all ten DOE terms (factor, level, run, randomization, replication,
   blocking, response, interaction, design matrix, experimental unit) and name
   the CPPC violation and consequence attached to each.
2. Explain structurally why OFAT misses interactions, using the Module 28
   machine x coating inversion as the worked counterexample.
3. Classify arbitrary experimental artifacts (a setting, a trial, a measured
   output, a time group) into the correct term.
4. Compute run counts and error degrees of freedom for a replicated, blocked
   2^k factorial (e.g. 2^4 x 3 with 2 blocks → error df 31, python3-derived).
5. Detect the repeated-measurement trap: show that 3 gauge sub-measures of one
   housing underestimate true error MS by ~(gauge sd / process sd)^2 ~ 1/219.

## Module overview

**DMEDI phase:** Develop
**Running case:** CascadeProjects Precision Components (CPPC)
**Purpose:** establish the vocabulary and the experimental discipline that
Modules 30 (full factorial), 31 (fractional factorial), and 32 (RSM) build on.
Every term below is defined WITH a CPPC violation of it and the observed or
plausible consequence — the definition is the discipline, not the dictionary.
**Primary factors (pinned by RUNNING-CASE.md):** spindle speed (RPM), feed rate
(mm/min), coolant concentration (%), tool coating (coated/uncoated).
**Responses (pinned):** bore diameter deviation from 12.000 mm (um) and
surface finish Ra (um).

**Session timing** (2.5 h total): overview (10 min); OFAT spine, §1
(15 min); terminology walkthrough, §2 — one violation discussed per term
(60 min); grammar of a designed experiment, §3 (20 min); lab exercises, §4
(35 min); key check against `keys/solution-key.md` + debrief (20 min).

**Tool note:** Minitab — Stat > DOE > Factorial > Create Factorial Design is
where Modules 30–31 execute this grammar (nothing to analyze yet in this
module). python3 mirror — exercise 3 and 4 arithmetic is stdlib one-liners
(run counts, df, variance ratios; see `keys/solution-key.md` for the exact
commands); the numeric worked data lives in Module 30's
`data/doe-2k-full.csv`.

## 1. Why OFAT fails (the module's spine)

One-Factor-At-a-Time (vary speed while holding feed/coolant/coating fixed, then
vary feed, ...) misses interactions by construction: an OFAT experiment samples
only the edges of the design space, and any effect that changes sign or size
depending on another factor (like the machine x coating inversion in Module 28,
or the speed x feed interaction in Module 30) appears as noise or goes unseen.
DOE exists because CPPC's baseline Cpk = 0.72 was diagnosed with a year of OFAT
tribal tweaks that never closed the gap to Cpk 1.33.

## 2. Terminology — each with the CPPC violation and consequence

### Factor
A controllable input suspected of moving the response. CPPC factors: spindle
speed, feed rate, coolant concentration, tool coating.
**Violation:** the team "experimented" with coolant brand (uncontrolled
procurement churn) instead of a chosen factor.
**Consequence:** four months of drift attributed to "tool wear" was actually
brand-to-brand concentration variance; two tool-change studies were repeated
from scratch.

### Level
A specific setting of a factor. E.g. speed at 6000 vs 9000 RPM; coating at
coated vs uncoated.
**Violation:** levels set at "what the operator already uses" (8000 RPM) and
"slightly more" (8300 RPM) — a 4% span.
**Consequence:** the observed effect was indistinguishable from short-term
process noise (sigma = 7.407 um), the factor was declared inert, and speed was
excluded from the Module 30 design until the 6000/9000 re-screen brought it
back with the +12 um effect.

### Run (experimental run)
One trial: one combination of factor levels applied once, producing one (or
more) response measurements.
**Violation:** runs conflated with days — "we tested low speed on Tuesday."
**Consequence:** day-to-day temperature drift rode on the speed contrast;
the effect estimate doubled when the confounding was removed by re-randomizing
across days.

### Randomization
Running the design's runs in a chance-determined order so that unknown nuisance
variables (tool warm-up, operator, bar-stock lot) spread their noise across all
levels instead of aligning with one.
**Violation:** all low-speed runs first ("easier to program"), all high-speed
after.
**Consequence:** tool wear accumulated monotonically with the factor order; the
speed effect was confounded with time and the study was scrapped. This is the
single most common fatal DOE error at CPPC.

### Replication
Repeating a run at the same settings to measure pure experimental error
(within-run variance), giving every F test and effect SE its error term.
**Violation:** n=1 per condition, "the machine is repeatable."
**Consequence:** no error estimate existed, so "significant" meant "bigger than
I expected." Module 30 uses 2 replicates per corner precisely so SSE exists on
8 df; Module 28 uses 6 per cell.

### Blocking
Grouping runs into homogeneous blocks (a day, a bar-stock lot, a machine) so a
known nuisance factor is subtracted out rather than randomized away. Block what
you can, randomize what you cannot.
**Violation:** the coating comparison ran across two machines (M1 vs M3) without
blocking on machine.
**Consequence:** this is Module 28's planted interaction discovered as a
"coating failure" — the coating effect inverted across machines and the
unblocked comparison reported an average effect of nothing.

### Response
The measured output — in this course, the running case's CTQ carried by the
experiment (terminology per RUNNING-CASE.md: response = the CTQ Y the DOE
moves). Primary: bore deviation (um) = CTQ-1; secondary: Ra (um).
**Violation:** operators recorded "looks good / scrap" instead of the measured
diameter.
**Consequence:** a binary response with ~1/8 the information of the continuous
measurement; sample sizes needed to detect the +12 um speed effect ballooned
from 16 runs to 100+.

### Interaction
When the effect of one factor depends on the level of another (Module 28's
A x B; Module 30's speed x feed, -6 um).
**Violation:** OFAT culture — effects reported as single numbers in tribal
lore ("more feed always opens the bore").
**Consequence:** the lore was true at low speed and false at high speed; the
Module 30 factorial found speed x feed = -6 um, which OFAT structurally could
not see.

### Design matrix
The ordered list of level-combinations the experiment will run — the plan that
makes the study reproducible and balanced (Module 30 builds the 2^3 matrix).

### Experimental unit vs observation
The thing that receives the treatment (a machined housing under a settings
combination) vs the thing measured (its bore). Sub-measuring one housing 3
times is NOT 3 replicates — it is repeated measurement of one experimental unit.
**Violation:** bore measured 3x per housing, counted as n=3.
**Consequence:** error MS underestimated by ~an order of magnitude (gauge
repeatability, not process variance), false positives on a null coolant factor.

## 3. The grammar of a designed experiment

A DOE at CPPC answers: which factors move bore deviation, by how much, and do
they interact — with quantified uncertainty — in the fewest lawful runs.
Sequence taught here and executed in Module 30:

1. State the question and response(s); pick factors and levels (wide enough to
   clear the 7.407 um noise floor — the Module 29 "levels" violation).
2. Choose the design (2^k factorial for screening; Module 30 uses 2^3 = 8 runs
   x 2 replicates = 16).
3. Randomize run order; block on known nuisance (day).
4. Run, measure the response per experimental unit.
5. Compute effects, rank them (half-normal, Module 30), fit the model, check
   residuals, confirm with holdout runs.

## 4. Lab exercises

1. Classify each of the following as factor / level / run / response / block:
   "uncoated", "one housing machined at 9000 RPM + 300 mm/min", "Ra", "Tuesday
   morning".
2. Audit a real shop-floor "test": write down which of the ten terms above it
   violates, and the cheapest fix.
3. Compute the run count for a 2^4 factorial with 3 replicates and one blocked
   factor (2 blocks). How many df for error?
4. For the repeated-measurement trap: if gauge sd = 0.5 um and process sd = 7.407
   um, what is the ratio of a fake "error" MS (3 sub-measures of one housing)
   to the true error MS? (Expect roughly (0.5/7.407)^2 ~ 1/220.)

## Files

This module is conceptual; the worked data lives in Module 30
(`modules/30-full-factorial-doe/data/doe-2k-full.csv`).

## See also

Module 28 (two-way ANOVA — the inference machinery), Module 30 (2^3 full
factorial, worked end to end), RUNNING-CASE.md (pinned factors/responses).
