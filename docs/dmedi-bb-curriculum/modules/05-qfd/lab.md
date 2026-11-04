# Module 05 Lab — Full House of Quality: CPPC Gimbal Line

**Prereq**: slides-outline.md. **Time**: 2.0 h. **Tools**: python3, terminal.
Every number below re-derives via `python3 data/court.py` (exit 0 required).

## Part A — Left wing: CRs and importance points (20 min)

Input contract from Module 04 (`data/qfd-cppc-weights.csv`):

| CR | attribute | Kano id | spine CTQ | Kano | rank | points100 |
|---|---|---|---|---|---|---|
| CR1 | bore-diameter-in-spec | K-01 | CTQ-1 | M | 2 | 18 |
| CR2 | no-leaking-hydraulic-ports | K-02 | — | M | 1 | 20 |
| CR3 | certification-paperwork | K-03 | — | M | 6 | 9 |
| CR4 | bore-surface-finish-low-Ra | K-04 | — | O | 3 | 16 |
| CR5 | order-to-ship-lead-time | K-05 | CTQ-2 | O | 4 | 13 |
| CR6 | competitive-unit-cost | K-06 | CTQ-3 | O | 5 | 11 |
| CR7 | laser-etched-serialization | K-07 | — | A | 7 | 7 |
| CR8 | live-production-dashboard | K-08 | — | A | 8 | 4 |
| CR9 | weekly-quality-trend-report | K-10 | — | I | 9 | 2 |

Sum of points100 = **exactly 100** (largest-remainder allocation of (10−rank)/45 × 100;
K-09 premium packaging was dropped in Module 04 as indifferent and non-contractual).

**Traceability note (id namespaces).** The `Kano id` column cites Module 04's
customer-perception attribute ids (`kano-responses.csv`, K-01..K-10) — Kano
attributes are NOT CTQs; the CTQ tree derives from them. The `spine CTQ` column
names the running-case CTQ (RUNNING-CASE.md) each row derives into: K-01 → CTQ-1
(bore, 12.000 ± 0.025 mm), K-05 → CTQ-2 (lead time 18.4 d → ≤ 7 d), K-06 → CTQ-3
(cost $41.80 → ≤ $28.50). Blank (`—`) rows feed engineering characteristics (ECs)
directly without a spine CTQ of their own.

## Part B — Ceiling: engineering characteristics (15 min)

| EC | name | baseline | target |
|---|---|---|---|
| EC1 | bore-diameter-tolerance-mm | spec ±0.025; Cpk 0.72 pinned | 12.000 ± 0.008 (internal guard-band) |
| EC2 | surface-finish-Ra-um | 1.6 | ≤ 0.8 |
| EC3 | leak-test-fail-ppm | 1200 | 0 |
| EC4 | order-to-ship-lead-time-d | 18.4 | ≤ 7 |
| EC5 | unit-cost-usd | 41.80 | ≤ 28.50 |
| EC6 | etch-first-pass-readable-pct | 85 | ≥ 95 |

EC1 target math (shown, not asserted): centered process at σ = 2.0 um inside a
±0.008 mm guard-band gives Cpk = 0.008/(3 × 0.0020) = **1.33** — the Define-gate
target. Against the customer spec ±0.025 mm the same σ gives Z = 0.025/0.0020 =
**12.5σ**. EC4/EC5 are the spine constants (18.4 d → ≤ 7 d; $41.80 → ≤ $28.50).

## Part C — Body: 9/3/1 relationship matrix (30 min)

`data/qfd-cppc-matrix.csv` (blank = no relationship):

| CR | w | EC1 | EC2 | EC3 | EC4 | EC5 | EC6 | row sum | weighted |
|---|---|---|---|---|---|---|---|---|---|
| CR1 | 18 | 9 | 3 | | | 3 | | 15 | 270 |
| CR2 | 20 | 1 | | 9 | | 1 | | 11 | 220 |
| CR3 | 9 | | | | 3 | | 1 | 4 | 36 |
| CR4 | 16 | 3 | 9 | | | | | 12 | 192 |
| CR5 | 13 | | | | 9 | | | 9 | 117 |
| CR6 | 11 | 1 | 1 | | | 9 | | 11 | 121 |
| CR7 | 7 | | | | 1 | | 9 | 10 | 70 |
| CR8 | 4 | | | | 1 | | 1 | 2 | 8 |
| CR9 | 2 | | | | 1 | | 1 | 2 | 4 |

Row sums (done by hand for CR1: 9+3+3 = 15; weighted 18×15 = 270) are a coverage
check: a CR with row sum 0 is unaddressed by every EC. CR3/CR8/CR9 (row sums 4/2/2)
are thin — flagged, not fixed: they are paperwork/IT features, deliberately
out-scoped from the machining-line EC set.

## Part D — Footer: technical importance (20 min)

Weighted column totals: EC_i = Σ w × cell.

| EC | derivation | total | rank |
|---|---|---|---|
| EC1 | 18×9 + 20×1 + 16×3 + 11×1 | **241** | 1 |
| EC2 | 18×3 + 16×9 + 11×1 | **209** | 2 |
| EC3 | 20×9 | **180** | 3 |
| EC4 | 9×3 + 13×9 + 7×1 + 4×1 + 2×1 | **157** | 5 |
| EC5 | 18×3 + 20×1 + 11×9 | **173** | 4 |
| EC6 | 9×1 + 7×9 + 4×1 + 2×1 | **78** | 6 |

Conservation: Σ columns = 241+209+180+157+173+78 = **1038** = Σ weighted rows
(270+220+36+192+117+121+70+8+4). If these disagree, the matrix arithmetic is wrong —
the court checks this identity.

## Part E — Roof: correlation matrix (20 min)

All C(6,2) = 15 pairs (`data/qfd-cppc-roof.csv`):

| pair | score | rationale |
|---|---|---|
| EC1–EC2 | + | tighter process control improves finish together |
| EC1–EC3 | + | bore geometry (concentricity) drives port sealing |
| EC1–EC5 | −− | tighter tolerance raises machining cost directly |
| EC2–EC5 | − | finer finish = slower feeds = cost |
| EC3–EC5 | − | leak prevention adds process-control cost |
| EC4–EC5 | + | flow improvements cut cost-to-serve |
| EC5–EC6 | − | etching adds per-unit cost |
| remaining 8 pairs | 0 | no meaningful coupling |

Reading: EC5 conflicts with 4 of 15 pairs — the cost EC is the system constraint.
Headline consequence: reach Cpk 1.33 by reducing σ to ≤ 2.0 um (process work),
never by tightening the print — that path is roof-blocked (EC1–EC5 −−).

## Part F — Secondary transactional QFD: insurance claims SLA (30 min)

Weights re-derived by a SECOND method — direct rating 1–10, normalized to 100
(`data/qfd-claims-weights.csv`):

| CR | name | rating | weight |
|---|---|---|---|
| C1 | fast-claim-decision | 9 | 22 |
| C2 | payment-accuracy | 8 | 20 |
| C3 | status-transparency | 3 | 7 |
| C4 | digital-submission | 6 | 15 |
| C5 | plain-language-comms | 5 | 13 |
| C6 | data-security | 9 | 23 |

Matrix (`data/qfd-claims-matrix.csv`), ECs T1 decision-cycle-time (12 d → ≤3),
T2 first-pass-yield (71% → ≥95), T3 rework-loops (1.8 → ≤0.2), T4 digital-adoption
(38% → ≥80), T5 complaints/1k (6.5 → ≤2.0), T6 audit-exceptions (9% → ≤2):

| CR | w | T1 | T2 | T3 | T4 | T5 | T6 | row sum |
|---|---|---|---|---|---|---|---|---|
| C1 | 22 | 9 | 3 | 3 | | | | 15 |
| C2 | 20 | | 9 | 3 | | | 3 | 15 |
| C3 | 7 | 1 | | 3 | | 3 | | 7 |
| C4 | 15 | 3 | | | 9 | | | 12 |
| C5 | 13 | | 1 | | | 9 | | 10 |
| C6 | 23 | | | | 3 | | 9 | 12 |

Column totals: T1 **250**, T2 **259**, T3 **147**, T4 **204**, T5 **138**, T6 **267**
(conservation: Σ = 1265 = Σ weighted rows 330+300+49+180+130+276). Roof: T1–T3 and
T2–T3 both −− — rework loops are the transactional system constraint, same lesson
as EC5 in the product QFD.

## Part G — Court (5 min)

```bash
python3 data/court.py   # exit 0 required; also re-runs the module-04 court
```
