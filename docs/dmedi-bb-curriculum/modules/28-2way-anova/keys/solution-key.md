# Module 28 — Solution Key (lab-interaction-plot.md and README §7)

Every number below was re-derived from `data/anova-2way.csv` (column
`bore_deviation_mm`) with python3; receipt: `python3` heredoc over the
README §3 script (corrected column name), exit 0, 2026-11-04. Do not trust
this key — re-run it.

## 1. ANOVA table values (README §4 verified)

| Source | SS (mm^2) | df | MS (mm^2) | F |
|---|---|---|---|---|
| Machine (A) | 0.000038227 | 2 | 0.000019113 | 4.63 |
| Coating (B) | 0.000039690 | 1 | 0.000039690 | 9.61 |
| A x B | 0.000484272 | 2 | 0.000242136 | 58.63 |
| Error | 0.000123893 | 30 | 0.000004130 | |
| Total | 0.000686082 | 35 | | |

- Closure: SST − (SSA+SSB+SSAB+SSE) = 0.000e+00 (exact; SSE by subtraction).
- sigma-hat = sqrt(MS_E) = 2.032 um — matches the seeded N(0, 2 um) noise.

## 2. Exercise 1 + 2 — SSE by subtraction equals SSE direct

Direct within-cell SSE computed independently: 0.000123893 mm^2.
By-subtraction SSE: 0.000123893 mm^2. Difference: 5.12e-14 < 1e-9. PASS.

Derivation shown: SSE_direct = sum over 6 cells of sum over the 6 replicates
of (y − cell_mean)^2. E.g. cell (M1, coated) mean = (12.0068+12.0067+...)/6;
each replicate contributes one squared residual; 36 residuals total, df = 30.

## 3. Exercise 3 — verdict: CROSSED

Coated line: +6.5 (M1) → +6.2 (M2) → +16.2 (M3). Uncoated: +14.1 → +13.1 →
+7.9. The polylines cross between M2 and M3 (coated goes from 7.9 um BELOW
uncoated to 8.3 um ABOVE it). Interaction confirmed visually, F_AB = 58.63
confirms it numerically.

## 4. Exercise 4 — simple effects (SE = 1.173 um, t crit = 2.042, df 30)

SE = sqrt(2 * MS_E / n) = sqrt(2 * 4.130e-6 / 6) mm = 1.173 um.

| Machine | coated − uncoated (um) | t = diff / 1.173 | significant at 0.05? |
|---|---|---|---|
| M1 | −7.617 | −6.49 | YES |
| M2 | −6.950 | −5.92 | YES |
| M3 | +8.267 | +7.05 | YES |

All three simple effects are significant. Coating HELPS on M1/M2 (by ~7.6 and
~7.0 um) and HURTS on M3 (by ~8.3 um) — magnitude ~2.4x the within-cell sigma
of 2.03 um. Shop policy: coated on M1/M2, uncoated on M3.

Note: the lab worksheet's exit criteria say t magnitudes "~6.5, ~5.9, ~7.1";
the exact values are 6.49, 5.92, 7.05 — consistent.

## 5. Exercise 5 — unit-change invariance

Re-expressing the response as deviation-from-12.000 in um multiplies every SS
by 1e6 (ratios checked: SST2/SST = 0.99999999992 * 1e6, SSA2/SSA = 1.0 * 1e6
within floating point), leaves every df unchanged, and therefore every F
ratio and p-value identical (F_A 4.63, F_B 9.61, F_AB 58.63 in both units).
Invariance PASS.

## See also

README §3 (derivation script — the source of every number here),
lab-interaction-plot.md (worksheet this key answers).
