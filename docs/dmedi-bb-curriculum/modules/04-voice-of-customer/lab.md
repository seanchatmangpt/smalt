# Module 04 Lab — Kano Evaluation on the CPPC Gimbal Customer-P Perception Attributes

**Prereq**: slides-outline.md slides 2–4. **Time**: 1.5 h. **Tools**: python3, terminal.

## Part A — Interview guide + sample dialogue (20 min)

Interview guide template (fill per customer; aerospace integrator "A-3" example):

| # | Probe | Purpose |
|---|---|---|
| 1 | Walk me through what happens to the housing between delivery and installation. | Map receiving inspection → assembly, find hidden rework. |
| 2 | What goes wrong most often? | Failure-story probe; source of K-01/K-04. |
| 3 | Tell me about the last time a housing arrived out of spec. What did it cost you? | Quantify cost-of-poor-quality in the customer's own units. |
| 4 | If you could change one thing about incoming housings, what? | Ideal-state probe; source of K-08 dashboard. |
| 5 | How often do you audit supplier paperwork? | Grounds K-03. |
| 6 | Rank these nine requirements by importance to you. | Feeds the CR1–CR9 ranking in Part C. |

Sample dialogue (excerpt, customer A-3, receiving-inspection lead):

> **BB**: "Tell me about the last time a housing arrived out of spec."
> **A-3**: "Two weeks ago — bore at 12.031. We quarantined the lot, re-inspected 100%,
> missed a launch-slot. Our inspector found the hydraulics port weeping after we
> finally released the bore. Two failures, one part."
> **BB**: "What would 'perfect' look like at receiving?"
> **A-3**: "Bore right the first time, dry leak-test certificate in the box, and —
> honestly — a status page so we don't find out by opening a crate."
> **BB**: "Rank these: bore in spec, no leaks, paperwork, finish, lead time, cost,
> laser etch, dashboard, trend report."
> **A-3**: "Leaks first — a weep costs us a flight lot. Then bore. Then finish.
> Then lead time. The trend report we take because the contract says we get one."

The last quote is the exact justification for retaining K-10 (indifferent, contractual).

## Part B — Kano questionnaire design (15 min)

Question-pair template (attribute X = bore surface finish):

- F: "If the bore finish is Ra 0.8 um or better, how do you feel?" → {I like it (A) / must be (M) / neutral (I) / can live with (D=I) / dislike (D=M)}
- D: "If the bore finish is Ra 1.6 um or worse, how do you feel?" → {like it (A) / must be (M) / neutral / can live with (I) / dislike (M)}

Evaluation table (memorize the shape, derive the cells):

| | D=A | D=M | D=I |
|---|---|---|---|
| **F=A** | Q | A | O |
| **F=M** | O | R | M |
| **F=I** | R | M | I |

Rules: Q responses are discarded before tallying (they carry no class bits). R means
the attribute is wanted absent — for the CPPC set no attribute classified R by majority.

## Part C — Worked Kano evaluation (40 min)

Data: `data/kano-responses.csv` — 120 rows, 10 Kano attributes (K-01..K-10) × 12 respondents, SEED 20261104
(generator `data/gen_kano.py`). Each row: `kano_id, kano_name, resp_id, func, dys` with
func/dys in {A, M, I}.

Run the evaluation:

```bash
python3 data/compute.py   # exits 0 only if every classification re-derives
```

Derivation shown (K-01, do this by hand for two attributes before trusting the script):

1. For each response row, look up (func, dys) in the Part B table → class letter.
2. Tally classes per attribute. K-01 tallies: M=9, O=2, I=1 → majority M (**must-be**).
3. Compute SI = (A + O)/n and DSI = −(O + M)/n. K-01: SI = 1/12 = 0.167,
   DSI = −11/12 = −0.917 → strongly dissatisfying when absent: must-be confirmed.
4. Majority rule, ties toward the stronger demand class (order M > O > A > I > R).
   Q responses were already discarded; the generator does not emit them.

Full tally table (verbatim from `python3 data/compute.py` output):

| Kano id | attribute | counts | majority | SI | DSI |
|---|---|---|---|---|---|
| K-01 | bore-diameter-in-spec | M9 O2 I1 | **M** | 0.167 | −0.917 |
| K-02 | no-leaking-hydraulic-ports | M10 I1 R1 | **M** | 0.000 | −0.833 |
| K-03 | certification-paperwork-per-shipment | M8 I1 Q2 A1 | **M** | 0.083 | −0.667 |
| K-04 | bore-surface-finish-low-Ra | O8 R2 M1 Q1 | **O** | 0.667 | −0.750 |
| K-05 | order-to-ship-lead-time | O7 A1 R1 M1 Q2 | **O** | 0.667 | −0.667 |
| K-06 | competitive-unit-cost | O8 R2 I1 A1 | **O** | 0.750 | −0.667 |
| K-07 | laser-etched-serialization | A8 O2 Q1 R1 | **A** | 0.833 | −0.167 |
| K-08 | live-production-status-dashboard | A8 M1 O1 I2 | **A** | 0.750 | −0.167 |
| K-09 | premium-packaging | I6 R4 Q1 A1 | **I** | 0.083 | 0.000 |
| K-10 | weekly-quality-trend-report | I6 M2 A2 R2 | **I** | 0.167 | −0.167 |

K-10 teaching point: six (I,I) draws + fill gives majority I — the attribute is
indifferent, yet retained as CR9 because the contract with A-3 names it. K-09
(premium packaging) is dropped entirely: indifferent AND not contractual.

ID-NAMESPACE NOTE — Kano attributes are NOT CTQs. The K-01..K-10 ids above are
customer-perception attributes; the CTQ tree DERIVES from them into the
running-case spine (RUNNING-CASE.md owns the CTQ-1/2/3 ids):

| Kano attribute | → CR (Part D) | spine CTQ derivation |
|---|---|---|
| K-01 bore-diameter-in-spec | CR1 | CTQ-1 (bore, 12.000 ± 0.025 mm) |
| K-05 order-to-ship-lead-time | CR5 | CTQ-2 (lead time, 18.4 d → ≤ 7 d) |
| K-06 competitive-unit-cost | CR6 | CTQ-3 (cost, $41.80 → ≤ $28.50) |
| K-02/K-03/K-04/K-07/K-08 | CR2/3/4/7/8 | no spine CTQ; feed Module 05 ECs directly |
| K-09 premium-packaging | — | dropped (indifferent, non-contractual) |
| K-10 weekly-quality-trend-report | CR9 | no spine CTQ; contractual retention |

## Part D — Ranking → weights (15 min)

Paired-ranking table for CR1–CR9 (final ranks after resolving A-3 vs integrator-B
rank disagreements; disagreement > 2 positions → keep the more demanding customer):

| CR | attribute | rank | points (10−rank) | weight | ×100 points |
|---|---|---|---|---|---|
| CR1 | bore diameter in spec | 2 | 8 | 0.178 | 18 |
| CR2 | no leaking hydraulic ports | 1 | 9 | 0.200 | 20 |
| CR3 | certification paperwork | 6 | 4 | 0.089 | 9 |
| CR4 | bore surface finish (Ra) | 3 | 7 | 0.156 | 16 |
| CR5 | order-to-ship lead time | 4 | 6 | 0.133 | 13 |
| CR6 | competitive unit cost | 5 | 5 | 0.111 | 11 |
| CR7 | laser-etched serialization | 7 | 3 | 0.067 | 7 |
| CR8 | live production dashboard | 8 | 2 | 0.044 | 4 |
| CR9 | weekly quality trend report | 9 | 1 | 0.022 | 2 |

Weight sum = 45/45 = 1.0; ×100 point column allocated by largest remainder
(4.44→4 for CR8, 2.22→2 for CR9) and sums to exactly 100. These 9 integer points
are the importance column of the Module 05 QFD house of quality.
