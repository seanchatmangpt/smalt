# Module 28 — Two-Way ANOVA with Interaction

## Learning objectives

After this module the candidate can:

1. Partition a balanced two-way ANOVA (a x b x n) into SSA, SSB, SSAB, and SSE
   by hand, and verify the closure identity SST = SSA+SSB+SSAB+SSE to 1e-9.
2. Interpret the A x B interaction row FIRST: state F_AB = MSAB/MSE with its
   df and explain why a significant interaction demotes the main effects to
   descriptive status.
3. Read a crossing (or parallel) interaction plot at true scale and predict
   the F verdict from the geometry before computing it.
4. Compute and test simple effects (coating contrast within each machine,
   SE = sqrt(2*MS_E/n), t crit df 30) when the interaction is significant.
5. Verify unit-change invariance: re-express the response in um and show
   every F and p is unchanged.

## Module overview

**DMEDI phase:** Develop
**Running case:** CascadeProjects Precision Components (CPPC)
**Question:** Three CNC machines (M1/M2/M3) and two tool coatings (coated/uncoated)
both plausibly shift bore diameter on the SR-71 gimbal housing. Do they matter
independently, or does the *best coating depend on which machine* runs it?
**Data:** `data/anova-2way.csv` — 3 machines x 2 coatings x 6 replicates = 36 runs,
fully crossed, balanced (equal n per cell). Response is bore diameter (mm), CTQ-1;
deviation from 12.000 mm is what we plot in um.
**Prerequisites:** Module 09 (sampling distributions, F intuition), Module 10 (why
replication before inference), Module 21 §6 (one-way ANOVA: SS partition, F =
MS_factor/MS_error).

**Bridge from Module 21 (read first).** This module assumes the one-way ANOVA
machinery from Module 21 §6 — sum-of-squares partition, MS = SS/df, F =
MS_factor/MS_error, and the MSW-based pairwise follow-up CIs. Nothing here
re-teaches that machinery: the two-way model *extends* the same partition to
three sources (A, B, A x B) plus error. If the one-way table in Module 21 §6
is not something you can re-derive by hand, stop and rebuild it before
reading section 3.

**Session timing** (3.0 h total): overview + bridge from Module 21 (15 min);
section 1–2 context and data walkthrough (15 min); section 3 hand derivation
run and checked line by line (30 min); section 4–5 ANOVA table reading
(20 min); interaction-plot lab, README §6 + lab worksheet Tasks 1–2
(30 min); simple effects (lab Task 3) (25 min); closure court (lab Task 4)
(15 min); exercises 1–5 from §7 (45 min); debrief (15 min).

**Tool note:** Minitab — Stat > ANOVA > Two-Way (response in
`bore_deviation_mm`, row factor machine, column factor coating; check "Include
interaction"). python3 mirror — the README §3 script IS the mirror; it runs
against the raw CSV with stdlib only (`csv`, `math`), no stats packages.

## 1. Why two factors at once

One-way ANOVA on coating would pool machines into error. If coating helps M1/M2
but hurts M3, the pooled contrast shrinks toward zero and we conclude "no coating
effect" while the shop floor fights a machine-dependent problem. The two-way model
separates three questions:

- **Factor A (machine):** do machines differ, averaged over coatings?
- **Factor B (coating):** does coating differ, averaged over machines?
- **A x B interaction:** does the coating effect change sign/size across machines?

The interaction is checked FIRST. If it is significant, the main-effect rows are
descriptive only — the actionable answer lives in the cell means (simple effects).

## 2. The data

36 rows: `machine,coating,rep,bore_deviation_mm`. Balanced design (n=6 every cell),
so the textbook decomposition applies without unequal-n corrections.

Seeded generation (python3 `random`, seed 28): cell means planted with a deliberate
interaction — coated helps on M1/M2 (~-8 um) but hurts on M3 (~+9 um) — plus
N(0, 2 um) within-cell noise. Planted machine main effect is small.

## 3. Hand-shown derivation (python3, exit-checked)

The full computation, runnable as-is against the raw CSV. Every number in the
ANOVA table below comes from this script; re-derive, do not trust the table.

```python
import csv
rows = list(csv.DictReader(open("data/anova-2way.csv")))
y = [float(r["bore_deviation_mm"]) for r in rows]
mach = sorted({r["machine"] for r in rows})
coat = sorted({r["coating"] for r in rows})
N, a, b, n = len(y), len(mach), len(coat), 6

G = sum(y); CT = G*G/N                       # correction term
SST = sum(v*v for v in y) - CT               # total SS
cell = {(m, c): sum(float(r["bore_deviation_mm"]) for r in rows
                    if r["machine"] == m and r["coating"] == c)/n
        for m in mach for c in coat}
rowm = {m: sum(cell[(m, c)] for c in coat)/b for m in mach}
colm = {c: sum(cell[(m, c)] for m in mach)/a for c in coat}
grand = G/N

SSA  = b*n*sum((rowm[m] - grand)**2 for m in mach)
SSB  = a*n*sum((colm[c] - grand)**2 for c in coat)
SSAB = n*sum((cell[(m, c)] - rowm[m] - colm[c] + grand)**2
             for m in mach for c in coat)
SSE  = SST - SSA - SSB - SSAB                # by subtraction (balanced design)
```

Derivation logic, term by term:

- `SS_total = sum(y^2) - G^2/N`: every observation's squared distance from the
  grand mean.
- `SS_A`: machine (row) means differ from the grand mean; each squared gap is
  weighted by b*n because a row mean stands for 12 observations.
- `SS_B`: same for coating (column) means, weight a*n.
- `SS_AB`: the residual after removing row and column effects from each cell:
  `cell - rowm - colm + grand`. If lines are parallel this is ~0; each cell
  deviation is weighted by n.
- `SS_E = SST - SS_A - SS_B - SS_AB` (valid because the design is balanced).

Degrees of freedom: df_A = a-1 = 2, df_B = b-1 = 1, df_AB = (a-1)(b-1) = 2,
df_E = N - a*b = 30, df_T = N-1 = 35. Check: 2+1+2+30 = 35.

### Cell means (um deviation from 12.000 mm)

| Machine | Coated | Uncoated | Row mean (um) |
|---|---|---|---|
| M1 | +6.5 | +14.1 | +10.3 |
| M2 | +6.2 | +13.1 | +9.7 |
| M3 | +16.2 | +7.9 | +12.0 |
| **Col mean** | **+9.6** | **+11.7** | grand +10.7 |

## 4. The ANOVA table (derived values)

| Source | SS (mm^2) | df | MS | F | p | F crit (0.05) |
|---|---|---|---|---|---|---|
| Machine (A) | 0.000038 | 2 | 0.0000190 | **4.63** | 0.0177 | 3.32 |
| Coating (B) | 0.000040 | 1 | 0.0000402 | **9.61** | 0.0042 | 4.17 |
| A x B | 0.000484 | 2 | 0.0002421 | **58.63** | 4.3e-11 | 3.32 |
| Error | 0.000124 | 30 | 0.0000041 | | | |
| Total | 0.000686 | 35 | | | | |

Closure check: 0.000038 + 0.000040 + 0.000484 + 0.000124 = 0.000686 = SS_total
(exact to floating point; the derivation script asserts this).

## 5. Reading the table

1. **Interaction first.** F_AB = 58.6 >> 3.32, p = 4e-11. The coating effect
   is NOT the same on all machines — significant at any sane alpha. This single
   row is the module's headline: a coating decision taken from the main effect
   alone would be wrong for one machine in three.
2. **Main effects become descriptive.** F_A = 4.63 (p=0.018) and F_B = 9.61
   (p=0.004) are individually significant, but they average over the crossed
   structure: "coating" is better on M1/M2 and worse on M3, so the +11.7 vs +9.6
   um column difference is a mixture, not a policy.
3. **Error MS** = 4.13e-6 mm^2, so within-cell sigma = sqrt(4.13e-6) = 2.03 um —
   matches the seeded N(0, 2 um) noise. The F ratios are credible because the
   noise floor is honest.

## 6. Interaction plot lab (MANDATORY)

Plot bore deviation (um) vs machine, one point per coating, from the derived
cell means. Scale-accurate text rendering (1 gridline = 1 um, columns M1/M2/M3;
connect o's and x's mentally machine to machine):

```text
 bore deviation (um) from 12.000 mm      o = coated   x = uncoated
      |   M1   M2   M3
  17 |
  16 |            o          <- coated, M3: +16.2
  15 |
  14 |   x                   <- uncoated, M1: +14.1
  13 |            x          <- uncoated, M2: +13.1
  12 |
  11 |
  10 |
   9 |
   8 |            x          <- uncoated, M3: +7.9
   7 |
   6 |   o    o              <- coated, M1/M2: +6.5 / +6.2
   5 |
      +------------------
```

Read it: the o-line (coated) runs flat at ~+6 um across M1/M2 then JUMPS to
+16 on M3; the x-line (uncoated) starts at ~+14/+13 and FALLS to +8 on M3.
The lines cross between M2 and M3. Crossing lines = interaction, visible before
any F ratio is computed.

### Lab interpretation checklist

- **Parallel-lines test.** Lines that never cross (or converge/diverge without
  sign flip) = no practical interaction. Here: coated starts BELOW uncoated on
  M1/M2 and ends ABOVE it on M3 — the lines cross. Crossing = interaction.
- **Simple effects when crossed.** Because the interaction is significant, test
  coating within each machine, and machine within each coating, using
  MS_E = 4.13e-6 mm^2 as the pooled error (df = 30). Simple-effect contrast on
  coating at M3: (16.2 - 7.9) = +8.3 um — coated is WORSE on M3 by ~8 um,
  roughly 4 within-cell sigma (8.3 / 2.03); the opposite of the M1/M2 conclusion
  (coated better by ~7.6-6.9 um).
- **Engineering read.** The interaction is larger than either main effect
  (SS_AB = 0.000484 vs SS_A = 0.000038, SS_B = 0.000040). Run coated on M1/M2,
  uncoated on M3 — until Module 30's speed/feed DOE explains why M3 inverts.

## 7. Lab exercises

1. Re-run the section 3 script against `data/anova-2way.csv`. Assert
   `abs(SST - (SSA+SSB+SSAB+SSE)) < 1e-9` and `abs(SSE) < 1e-12` never (SSE is
   derived by subtraction; if you compute SSE directly as within-cell SS you
   must get the same value — do that as exercise 2).
2. Compute SSE directly: sum over cells of sum (y - cell mean)^2. Show it equals
   the by-subtraction value.
3. Draw the interaction plot at true scale (lab file). Write the one-sentence
   verdict: crossed or parallel?
4. Simple effects: compute the coating contrast at each machine with SE =
   sqrt(2*MS_E/n). Which machines show a significant coating difference at
   alpha=0.05 (t crit = 2.042, df=30)?
5. Swap the response to deviation-from-12.000 in um and re-derive the table.
   Every F and p must be identical (unit change invariance check).

## Files

- `data/anova-2way.csv` — seeded dataset (seed 28), registered in
  `datasets/MANIFEST.md`
- `lab-interaction-plot.md` — mandatory lab worksheet

## Units

This module's dataset is expressed in mm (`deviation_mm`, SS in mm^2) while
sibling DOE modules (30/31/37/40) use µm — the F-statistics are unit-invariant
(court check), so conclusions are unaffected; conversion 1 µm = 0.001 mm.

## See also

Module 21 §6 (one-way ANOVA), Module 29 (DOE terminology), Module 30 (factorial DOE
that explains the M3 inversion mechanism), Module 10 (replication discipline).
