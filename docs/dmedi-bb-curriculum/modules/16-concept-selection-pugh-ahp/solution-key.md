# Module 16 — Solution Key: Concept Selection (Pugh + AHP)

Every number below is an output of `python3 scripts/derive_selection.py`
(captured exit 0 in `data/court-run.txt`) or of the snippets shown inline.
Nothing is asserted from memory. Data: `data/concept_trials.csv`,
seed 1607, 30 pieces per concept.

# 1. Pilot statistics (re-derived from the CSV)

| concept | n | mu (mm) | s (mm) | Cpk | mean Ra (um) |
|---|---|---|---|---|---|
| A-citizen-regrind | 30 | 12.0087 | 0.00751 | 0.72 | 1.57 |
| B-peck-deep-drill-then-bore | 30 | 12.0033 | 0.00465 | 1.55 | 1.33 |
| C-helical-interpolation | 30 | 12.0042 | 0.00667 | 1.04 | 2.09 |
| D-combined-rough-plus-finish-boring-bar | 30 | 12.0024 | 0.00409 | 1.84 | 0.94 |

Derivation shown for A (identical law for B/C/D):

- mu = (1/30) * sum(bore_mm) = 12.0087 mm
- s = sqrt( sum((x - mu)^2) / 29 ) = 0.00751 mm = 7.51 um — the pilot
  estimate of the adjudicated spine sigma 7.407 um (within 15%, court
  check PASS).
- Cpk = min(USL - mu, mu - LSL) / (3 s)
       = min(12.025 - 12.0087, 12.0087 - 11.975) / (3 * 0.00751)
       = 0.0163 / 0.02253 = **0.72** — reproduces the pinned baseline Cpk
  0.72. This is the adjudicated pair; any 4.17 um-derived figure is stale.
- mean Ra = (1/30) * sum(ra_um) = 1.57 um.

# 2. Pugh matrix — iteration 1 (datum = A)

## 2.1 Datum justification (full sentences)

The datum is A, the incumbent citizen-regrind route, for three reasons:
(1) it is the process that is actually producing Cpk = 0.72 today, so it
is the counterfactual the gate review must beat; (2) every + / - / 0 is
then a statement about CHANGE from status quo, which is the only thing a
capital decision can act on; (3) its parameters are pinned in
RUNNING-CASE.md (12.009 mm, 7.407 um), so its marks re-derive from the
registered CSV. A non-incumbent datum (e.g. C) would only tell you how
each concept compares to C, not whether the portfolio beats doing nothing
new.

## 2.2 Scoring bases (stated before marks)

- C1 (capability): + iff pilot Cpk - datum Cpk >= +0.20; - iff gap <=
  -0.20; else 0. The band keeps 30-piece sampling noise from minting
  marks.
- C2 (finish): + iff datum Ra - concept Ra >= 0.15 um; - iff concept Ra -
  datum Ra >= 0.15 um; else 0.
- C3 (cycle): route facts, 22/14/11/17 min.
- C4 (cost): route facts, added capital $0 / $18k / $0 / $34k.
- C5 (flexibility): route facts, setups and tool sourcing.

## 2.3 Marks and rationale per cell

| criterion | A | B | C | D |
|---|---|---|---|---|
| C1 capability | 0 | + | + | + |
| C2 finish | 0 | + | - | + |
| C3 cycle | 0 | + | + | + |
| C4 cost | 0 | - | + | - |
| C5 flex | 0 | + | - | - |

Cell rationale (court-checkable strings from the engine):

- (B, C1) + — pilot Cpk 1.55 vs datum 0.72; gap +0.83 vs +/-0.20 band.
- (C, C1) + — pilot Cpk 1.04 vs datum 0.72; gap +0.32 >= 0.20.
- (D, C1) + — pilot Cpk 1.84 vs datum 0.72; gap +1.12.
- (B, C2) + — Ra 1.33 vs datum 1.57; lower by 0.24 um >= 0.15 band.
- (C, C2) - — Ra 2.09 vs 1.57; higher by 0.52 um.
- (D, C2) + — Ra 0.94 vs 1.57; lower by 0.63 um.
- (B, C3) + (14 vs 22 min); (C, C3) + (11 vs 22); (D, C3) + (17 vs 22).
- (B, C4) - ($18k deep-cycle tooling vs $0); (C, C4) + ($0, existing end
  mill); (D, C4) - ($34k custom bar).
- (B, C5) + (commodity tooling, standard practice); (C, C5) -
  (program-rigor sensitive); (D, C5) - (single-source custom tool).
- All (A, *) cells 0 — datum by construction (court check PASS).

## 2.4 Tallies

- A: +0 -0 0:5, net 0
- B: +4 -1, net **+3**
- C: +3 -2, net +1
- D: +3 -2, net +1
- Iteration-1 ranking: **B > C = D > A** (court check: leader is B — the
  designed divergence with AHP, see section 5).

# 3. Pugh consolidation — iteration 2 (concept D2)

D carries only cost (custom $34k bar) and flexibility (single-source)
minuses. Consolidation: graft B's commodity coated-insert strategy onto
D's bar.

**D2 = combined rough + finish boring bar with standard coated insert set,
single setup.** Re-scored ONLY in changed cells, against the SAME datum A:

| criterion | D (iter 1) | D2 (iter 2) | basis |
|---|---|---|---|
| C1 | + | + | unchanged: Cpk 1.84, gap +1.12 |
| C2 | + | + | unchanged: Ra 0.94, gap 0.63 um |
| C3 | + | + | unchanged: 17 min |
| C4 | - | 0 | standard inserts remove the custom-bar premium (residual ~ regrind consumables) |
| C5 | - | + | commodity inserts, single setup — flexible like B |

D2 tallies +3 -0 (net **+3**). D2 TIES B (net +3 = +3).

**Pugh convergence law applied**: a tie is NOT resolved by trading marks
(each trade is unverifiable judgment creep). Escalate to (a) the raw data
— D beats B on both CTQ-1 axes: Cpk 1.84 vs 1.55 and Ra 0.94 vs 1.33 —
and (b) the weighted method (AHP, section 4). Both favor the D lineage.

# 4. AHP

## 4.1 Criteria pairwise matrix (authored from QFD relative weights)

```
           C1    C2    C3    C4    C5
C1          1    2     3     2     5
C2         1/2    1    2    1/2    4
C3         1/3  1/2    1    1/2    3
C4         1/2   2     2     1     4
C5         1/5  1/4  1/3   1/4    1
```

## 4.2 Criteria weights — two derivations shown

**Principal eigenvector** (power method, v0 = uniform, 200 iterations,
convergence tol 1e-12; then lambda_max = mean of (A w)_i / w_i):

- Weights: C1 0.3750, C2 0.1912, C3 0.1250, C4 0.2534, C5 0.0554
  (sum 1.0000, court check PASS).
- lambda_max = 5.1100. CI = (lambda_max - n)/(n - 1) = (5.1100 - 5)/4
  = 0.0275. RI(n=5) = 1.12. **CR = 0.0275 / 1.12 = 0.0246 < 0.10 →
  usable.**

**Geometric-mean cross-check** (row geometric means, normalized):
g_i = (prod of row i)^(1/5); weights = g_i / sum(g).
Row products: C1 = 1*2*3*2*5 = 60, g1 = 60^0.2 = 2.2679; C2 = 2, g2 =
2^0.2 = 1.1487; C3 = 0.25, g3 = 0.25^0.2 = 0.7579; C4 = 8, g4 = 8^0.2 =
1.5157; C5 = 1/240, g5 = (1/240)^0.2 = 0.3340. Sum 6.0242 → weights
0.3765, 0.1907, 0.1258, 0.2516, 0.0554 — matches the engine's
geometric-mean printout (0.3765 / 0.1907 / 0.1258 / 0.2516 / 0.0555) to
4 decimals and the eigenvector to ~2-3 decimals (difference is
power-method vs closed-form; both lawful).

## 4.3 The deliberately inconsistent matrix (teaching artifact)

CRIT_MAT_BAD claims cyclically: C1 >> C2 (9), C2 >> C3 (9), yet C1 ~ C3
(1). Result: lambda_max = 7.6162 vs n = 5 — inflation of +2.616 over
perfect consistency; CI = 0.6540; **CR = 0.5840 >= 0.10 → REFUSED.**

Repair attempts (computed, both insufficient):

- Change one judgment (C1~C3 → 4): lambda_max 6.5539, CR = 0.3468 — still
  refused.
- Repair the whole cyclic triad (C1>C2 = 3, C2>C3 = 3, C1>C3 = 4):
  lambda_max 5.9452, CR = 0.2110 — still refused.
- Conclusion: inconsistency is DISTRIBUTED; it lives in the other cells
  too (e.g. C4>C5 = 9 coexisting with C4~C2, C3>C5 = 1). The lawful fix
  is full reconstruction against the QFD-derived judgments — CRIT_MAT
  itself, CR 0.0246. **Teaching point: CR >= 0.10 is not repaired by
  spot-edits; the weights would be arithmetic on noise.**

## 4.4 Concept matrices per criterion (Saaty-snapped ratios)

Snap law: r is replaced by the nearest Saaty value in log space.
Matrices as printed by the engine (order A, B, C, D):

```
C1-capability (ratios of pilot Cpk, floored at 0.10)   CR 0.0170
     A     B     C     D
A  1.000 0.500 0.500 0.333
B  2.000 1.000 2.000 1.000
C  2.000 0.500 1.000 0.500
D  3.000 1.000 2.000 1.000
     -> priorities: A 0.1243  B 0.3257  C 0.1936  D 0.3564

C2-finish (inverse ratios of mean Ra)                  CR 0.0225
     A     B     C     D
A  1.000 1.000 1.000 0.500
B  1.000 1.000 2.000 0.500
C  1.000 0.500 1.000 0.500
D  2.000 2.000 2.000 1.000
     -> priorities: A 0.1976  B 0.2390  C 0.1682  D 0.3952

C3-cycletime (inverse ratios of route minutes)         CR 0.0225
     A     B     C     D
A  1.000 0.500 0.500 1.000
B  2.000 1.000 1.000 1.000
C  2.000 1.000 1.000 2.000
D  1.000 1.000 0.500 1.000
     -> priorities: A 0.1692  B 0.2879  C 0.3383  D 0.2046

C4-cost (ratios of authored cost factors 1.0/2.5/1.2/3.5) CR 0.0115
     A     B     C     D
A  1.000 3.000 1.000 4.000
B  0.333 1.000 0.500 1.000
C  1.000 2.000 1.000 3.000
D  0.250 1.000 0.333 1.000
     -> priorities: A 0.4039  B 0.1391  C 0.3404  D 0.1166

C5-flex (ratios of flexibility ordinals 3/4/2/2)       CR 0.0000
     A     B     C     D
A  1.000 1.000 2.000 2.000
B  1.000 1.000 2.000 2.000
C  0.500 0.500 1.000 1.000
D  0.500 0.500 1.000 1.000
     -> priorities: A 0.3333  B 0.3333  C 0.1667  D 0.1667
```

All five pass CR < 0.10 (court checks PASS).

## 4.5 Global scores (weighted sum shown per concept)

Global_i = sum_c (criterion weight) x (within-criterion priority_i).

- A = 0.3750(0.1243) + 0.1912(0.1976) + 0.1250(0.1692) + 0.2534(0.4039)
  + 0.0554(0.3333) = 0.0466 + 0.0378 + 0.0212 + 0.1023 + 0.0185 =
  **0.2263**
- B = 0.3750(0.3257) + 0.1912(0.2390) + 0.1250(0.2879) + 0.2534(0.1391)
  + 0.0554(0.3333) = 0.1221 + 0.0457 + 0.0360 + 0.0353 + 0.0185 =
  **0.2575**
- C = 0.3750(0.1936) + 0.1912(0.1682) + 0.1250(0.3383) + 0.2534(0.3404)
  + 0.0554(0.1667) = 0.0726 + 0.0322 + 0.0423 + 0.0863 + 0.0092 =
  **0.2425**
- D = 0.3750(0.3564) + 0.1912(0.3952) + 0.1250(0.2046) +
  0.2534(0.1166) + 0.0554(0.1667) = 0.1337 + 0.0756 + 0.0256 + 0.0296 +
  0.0092 = **0.2736**

**AHP ranking: D (0.2736) > B (0.2575) > C (0.2425) > A (0.2263).**

## 4.6 Equal-weight rerun (E5 answer)

With all weights 0.2: A 0.2456, B 0.2650, C 0.2414, D 0.2479 —
ranking **B > D > A > C**. The ONLY thing changed is the weighting, and
the winner flips D → B. Breadth (B's four pluses) wins unweighted;
depth on C1/C2 wins weighted. This is the module's core lesson in one
rerun.

# 5. Agreement / divergence analysis

- Pugh iteration 1 (unweighted marks): B > C = D > A — leader B.
- AHP (weighted): D > B > C > A — leader D.
- **The divergence is designed and witnessed** (court check PASS:
  iteration-1 winner differs from AHP winner). Mechanism: Pugh counts
  criteria equally (each mark worth 1); B's single cost minus is drowned
  by four pluses. AHP weights capability 0.375 and cost 0.253, and D
  leads capability (0.3564) and finish (0.3952) while carrying a worse
  cost priority than B (0.1166 vs 0.1391). The divergence arithmetic,
  term by term: D gains 0.375 x (0.3564 - 0.3257) + 0.1912 x (0.3952 -
  0.2390) = 0.0115 + 0.0299 = 0.0414 on capability+finish, and loses
  0.2534 x (0.1391 - 0.1166) = 0.0057 on cost, 0.1250 x (0.2879 - 0.2046)
  = 0.0104 on cycle time, and 0.0554 x (0.3333 - 0.1667) = 0.0092 on
  flexibility. Net: +0.0414 - 0.0057 - 0.0104 - 0.0092 = +0.0161 —
  exactly the D-over-B AHP margin (0.2736 - 0.2575). Term by term, the
  weighted method flips the winner because the capability+finish gain
  outweighs the cost/cycle/flexibility losses.

- Consolidation ties D2 with B at net +3; the tie is escalated (data +
  weights), not vote-traded (court checks PASS).
- Final: carry **D2** into detailed design (module 27). B = runner-up and
  fallback. C killed: worst Ra (2.09 um) and thinnest capability margin
  (Cpk 1.04 < 1.33 target). A = datum and no-capital fallback.
- AHP margin over B: (0.2736 - 0.2575)/0.2575 = 6.3% — a real margin but
  not a landslide; module 18 (Monte Carlo) must show D2's capability
  margin survives input variation before capital release.

# 6. Exercise answers (E1–E8)

- **E1**: see 2.1 (three reasons). Using C as datum: the matrix would
  rank concepts against C's profile (fast, cheap, poor finish) and could
  recommend A (!) — it would NOT answer whether the portfolio beats the
  status quo, and C is itself a candidate, so the datum is not
  decision-neutral.
- **E2**: with band 0.10 no C1 cell flips (gaps +0.83, +0.32, +1.12 all
  still >= 0.10); closest to flipping is C at +0.32. The 0.20 band exists
  because with n = 30 the standard error of a Cpk estimate at Cpk ~ 1 is
  roughly 0.15-0.25; a 0.10 band would mint marks from noise.
- **E3**: eigenvector weights 0.4340, 0.1960, 0.1176, 0.2102, 0.0422;
  lambda_max = 5.0877, CI = 0.0219, CR = 0.0196 < 0.10 → usable as
  given (note the exercise supplies C1 vs C3 = 4; a 5x5 matrix needs 10
  judgments).
- **E4**: one-judgment repair CR = 0.3468; triad repair CR = 0.2110 —
  both still refused (see 4.3). Answer: no single-judgment repair
  suffices; full reconstruction required.
- **E5**: see 4.6.
- **E6**: E pilot (seed 1608, mu 12.0035, sigma 0.0055, Ra center 1.8):
  mu = 12.0043, s = 0.00603, Cpk = 1.15, Ra = 1.82 um. Five-concept AHP
  (same law, all matrices CR < 0.02): global A 0.1830, B 0.2036, C
  0.2013, D 0.2297, E 0.1824 — ranking **D > B > C > A > E**. E does not
  displace D; its capability priority 0.1865 is below D's 0.3047.
- **E7**: raw-ratio C2 matrix: priorities A 0.2175, B 0.2559, C 0.1633,
  D 0.3632; lambda_max = 4.0003, CR = 0.0001. Order identical to the
  snapped matrix (D > B > A > C); the snap preserved order, so the
  conclusion is scale-robust.
- **E8**: memo skeleton: recommendation D2; divergence narrative (B vs D
  iteration 1); tie + escalation; AHP margin 6.3% over B; C killed
  (finish 2.09 um worst-in-set, Cpk 1.04 < 1.33); A retained as
  no-capital fallback; module 18 Monte Carlo must show the capability
  margin survives variation before capital release.
