# Module 08 — Minitab Quick-Start: Your First Session on Real Data

Case: CascadeProjects Precision Components (CPPC) — SR-71 gimbal housing, CTQ-1 bore
diameter (spec 12.000 ± 0.025 mm). Dataset: `data/bore-baseline-100.csv` (n=100,
seed 42008, `random.gauss(12.009, 0.007407)` — the adjudicated spine sigma — from
the Measure-phase baseline).

## Learning objectives

By the end of this module you can: open a CSV in Minitab, run Describe, produce a
histogram with spec limits, read a Session Window output line by line, and save a
reproducible project. Every number Minitab reports for this dataset is re-derived in
`solution-key.md` via python3 — the key is the answer sheet, the CSV is the truth.

## 1. The Minitab workspace (5-minute tour)

Minitab has three panes:

- **Worksheet** — a spreadsheet. Columns are C1, C2, ...; each column holds ONE
  variable. Rows are observations.
- **Session window** — the text log of every analysis. This is your receipt; it can
  be saved and re-read.
- **Navigator / graphs** — every graph is a separate window, saved inside the
  project file (.MPX).

Rule for this course: **one column = one variable, one row = one part/order**. Never
stack two samples in one column without a grouping column.

## 2. Lab: open the bore baseline

**Step 1.** File > Open > Worksheet, change file type to *CSV*, open
`data/bore-baseline-100.csv`. Minitab imports:
- C1 `observation` (1..100)
- C2 `bore_diameter_mm` (numeric, 11.9849–12.0293)

**Step 2.** Check the import: Stat > Basic Statistics > Display Descriptive
Statistics. Variables: `bore_diameter_mm`. Click **Statistics...** and tick N, Mean,
Median, StDev, Minimum, Maximum, Q1, Q3, Range, IQR. OK.

**Step 3.** Read the Session window. You should see (values verified in
`solution-key.md`):

```
Variable          N    Mean   StDev  Minimum      Q1   Median      Q3  Maximum
bore_diameter_mm 100 12.0098 0.0074  11.9849 12.0059 12.00995 12.0146 12.0293
```

Interpretation: the mean sits **9.8 um above nominal** (12.0098 vs 12.000) and one
bore (12.0293) already sits past USL. The process is not centered and the spread is
real — both are targets for the Improve phase.

**Step 4.** Graph > Histogram > Simple. Graph variable: `bore_diameter_mm`. Then
double-click the x-axis > **Reference lines**: add 11.975 and 12.025 (LSL/USL).
Add a second reference line at 12.000 (nominal). The whole distribution visibly
shifts right of nominal while still fitting inside the spec — low spread, off center.

**Step 5.** Save the project: File > Save Project As > `module08-lab.MPX`. Your
worksheet + graphs + session log travel together. That file is your first
**replayable receipt** — anyone can reopen it and get identical output.

## 3. Minitab habits that pay off all course

1. **Name columns properly on import** — Minitab output quotes the column name;
   `bore_diameter_mm` reads better in a report than `C2`.
2. **Session window first, graphs second** — the log is greppable and pasteable
   into gate-review decks; a screenshot is not.
3. **Units in the column name** — `_mm` vs `_um` is the #1 source of 1000x errors.
   This dataset is millimetres; Cpk arithmetic converts to um (7.407 um = 0.007407 mm).
4. **Do not hand-edit analysis output.** If a number looks wrong, fix the data or
   the dialog, never the report.

## 4. Exercise (do before the solution key)

Using the session-window output from Step 2 only:

a) How many bores would you expect outside spec if the process were centered at
   12.000 with the same spread? (Hint: compare the half-width of the spec to 3×StDev.)
b) What is the distance from the mean to the nearer spec limit, in units of StDev?
c) The largest bore in the file is 12.0293 mm. Which spec limit is it closest to —
   and is it inside or outside?
d) Re-open the CSV, sort `bore_diameter_mm` ascending, and confirm the median
   Minitab reported is the average of rows 50 and 51.

## 5. Checklist (gate)

- [ ] CSV imported; 100 rows; column named `bore_diameter_mm`
- [ ] Descriptives match the table in §2 Step 3 (4-decimal agreement)
- [ ] Histogram carries LSL 11.975, nominal 12.000, USL 12.025 reference lines
- [ ] Project saved as .MPX; session log export saved alongside
- [ ] Exercise 4a–4d answered and checked against `solution-key.md`

## Files

- `README.md` — this lesson
- `solution-key.md` — python3 re-derivation of every statistic + exercise answers

See also: Module 09 (deeper basic statistics, CLT), Module 10 (control charts on the
same bore process).
