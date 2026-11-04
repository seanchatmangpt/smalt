# Module 08 — Minitab Quick-Start (Slides Outline)

**Module**: 08-intro-minitab · Case: CPPC SR-71 gimbal housing, CTQ-1 bore diameter
Dataset: `data/bore-baseline-100.csv` (seed 42008, n=100)
**Timing**: 2.0 h (slides 40 min, lab 45 min, exercises 30 min, court 5 min)
**Tools**: Minitab (or the python3 mirror used in the lab), terminal

---

## Slide 1 — Why a statistics package, and why receipts (5 min)

- A Black Belt's analyses must be **replayable**: anyone re-opening the file gets the
  identical numbers. Minitab's session window is the receipt; the .MPX project is the replay.
- Course law (RUNNING-CASE.md): every solution key re-derives from the raw CSV,
  never from a remembered answer. Minitab output = one derivation; python3 = the check.
- Dataset contract: `data/bore-baseline-100.csv` — 100 bores, generated with
  `random.gauss(12.009, 0.007407)` (adjudicated spine sigma), seed 42008, rounded to 4 dp. The court script
  regenerates it byte-exact from the stated seed as its first check.

## Slide 2 — The workspace in 5 minutes (5 min)

- **Worksheet**: one column = one variable, one row = one part. C1 `observation`,
  C2 `bore_diameter_mm`.
- **Session window**: the greppable log; paste text, not screenshots, into gate decks.
- **Graph windows**: every graph lives inside the project; save the project, save the receipt.
- Rule: never stack two samples in one column without a grouping column.

## Slide 3 — Import and verify (10 min)

- File > Open > Worksheet > CSV. Then **always verify the import**: Stat > Basic
  Statistics > Display Descriptive Statistics with N, Mean, StDev, Min, Max, Q1, Q3, Range, IQR.
- The expected session-window line (re-derived in solution-key.md, court-checked):

| N | Mean | StDev | Minimum | Q1 | Median | Q3 | Maximum |
|---|---|---|---|---|---|---|---|
| 100 | 12.0098 | 0.0074 | 11.9849 | 12.0059 | 12.00995 | 12.0146 | 12.0293 |

- Reading: mean sits **+9.8 um above nominal** and the max bore (12.0293) is already
  past USL — the sample contains exactly one scrap part, the visible face of a
  Cpk-0.72 baseline (sample Cpk 0.68).

## Slide 4 — Histogram + reference lines (5 min)

- Graph > Histogram > Simple; reference lines at 11.975 (LSL), 12.000 (nominal),
  12.025 (USL). The distribution shifts visibly right of nominal while fitting inside
  the spec: low spread, off center.

## Slide 5 — The python3 mirror (10 min)

- Every Minitab number has a stdlib-only python3 mirror (solution-key.md §Re-derivation).
- Minitab's StDev uses the n-1 denominator; Q1/Q3 use (n+1)p interpolation — the key's
  `pct()` helper reproduces Minitab's quartile convention exactly. This is why the key
  prints Q1 12.0072 / Q3 12.0122 where naive percentile code differs.

## Slide 6 — Habits (5 min)

1. Name columns properly; carry units in the name (`_mm` vs `_um` is the #1 1000x error).
2. Session window first, graphs second.
3. Never hand-edit analysis output; fix data or dialog, never the report.
4. Seeds are part of the data's identity: a dataset without a stated seed is not replayable.

## Lab and assessment

- Lab: `lab.md` (import → descriptives → histogram → project save, python3 mirror).
- Exercises 1–8: `exercises.md` (answers in solution-key.md).
- Court: `courts/court.py` (exit 0 = every number re-derives from the CSV).
