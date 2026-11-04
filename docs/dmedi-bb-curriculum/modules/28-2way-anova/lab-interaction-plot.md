# Lab — Interaction Plot (Module 28, MANDATORY)

Name: ____________ Date: ____________

## Task 1 — Draw the plot at true scale

From `data/anova-2way.csv` compute the six cell means (or read them from
README section 3, but re-derive at least one cell by hand from the raw CSV).

Fill the grid, one character per cell mean. 1 row = 1 um.

```text
 bore deviation (um) from 12.000 mm      o = coated   x = uncoated
      |   M1   M2   M3
  17 |
  16 |
  15 |
  14 |
  13 |
  12 |
  11 |
  10 |
   9 |
   8 |
   7 |
   6 |
   5 |
      +------------------
```

Draw (with / and \ characters or a pencil line) the coated polyline M1-M2-M3
and the uncoated polyline M1-M2-M3.

## Task 2 — Parallel-lines test

- [ ] Coated line flat/rising/falling between M1-M2: ______
- [ ] Coated line between M2-M3: ______
- [ ] Uncoated line between M1-M2: ______
- [ ] Uncoated line between M2-M3: ______
- [ ] Do the polylines cross? YES / NO (circle one)

If NO (parallel): report the main effects as the answer.
If YES (crossed): main effects are NOT the answer. Go to Task 3.

## Task 3 — Simple effects (because the lines cross)

Pooled error from the ANOVA table: MS_E = 4.13e-6 mm^2 (df = 30),
so sigma = 2.03 um. Contrast SE for coating within one machine:
SE = sqrt(2 * MS_E / 6) = 1.17 um. t crit (0.025, df 30) = 2.042.

| Machine | coated - uncoated (um) | t = diff/1.17 | significant at 0.05? |
|---|---|---|---|
| M1 | +6.5 - 14.1 = -7.6 | | |
| M2 | +6.2 - 13.1 = -6.9 | | |
| M3 | +16.2 - 7.9 = +8.3 | | |

Verdict sentence (fill in): coating helps on machines ____ and ____ and HURTS
on machine ____, so the shop policy must be ____________________.

## Task 4 — Closure court

- [ ] Re-derived SS_total from the raw CSV: ______ (expect 0.000686 mm^2)
- [ ] SSA + SSB + SS_AB + SS_E sums to SS_total within 1e-9: YES / NO
- [ ] F_AB = MS_AB / MS_E = ______ (expect 58.63)
- [ ] F_AB > F crit (3.32): YES / NO — interaction significant

## Exit criteria

You may leave this lab when (a) your plot shows the crossing, (b) your simple-
effects table has all three t values computed (magnitudes ~6.5, ~5.9, ~7.1),
and (c) the closure court in Task 4 is all YES with your own numbers, not the
README's.
