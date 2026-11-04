# Module 08 Lab — First Minitab Session on the CPPC Bore Baseline

Run from the curriculum root. Dataset: **`data/bore-baseline-100.csv`** (seed 42008,
n=100 bores, adjudicated spine sigma 0.007407). Every step has a python3 mirror so the lab replays without Minitab.

## Part A — Import and describe (Minitab path) (20 min)

1. File > Open > Worksheet, file type CSV → `data/bore-baseline-100.csv`.
   Expected import: C1 `observation` (1..100), C2 `bore_diameter_mm` (11.9849–12.0293).
2. Stat > Basic Statistics > Display Descriptive Statistics → variables
   `bore_diameter_mm` → Statistics...: tick N, Mean, StDev, Minimum, Maximum, Q1, Q3,
   Range, IQR → OK.
3. Expected session-window line (court-checked in `courts/court.py`):

```
Variable          N    Mean   StDev  Minimum      Q1   Median      Q3  Maximum
bore_diameter_mm 100 12.0098 0.0074  11.9849 12.0059 12.00995 12.0146 12.0293
```

## Part B — python3 mirror (run it) (5 min)

```bash
python3 modules/08-intro-minitab/courts/court.py && echo COURT PASS
```

The court re-derives Part A's table from the CSV and additionally proves the dataset
regenerates byte-exact from seed 42008 (`random.gauss(12.009, 0.007407)`, 100 draws,
4-dp rounding) — the replay property Minitab's .MPX approximates.

## Part C — Histogram with spec reference lines (10 min)

Minitab: Graph > Histogram > Simple → `bore_diameter_mm` → double-click x-axis >
Reference lines: 11.975 / 12.000 / 12.025. python3 mirror (optional, stdlib-only):

```python
import csv
x = [float(r['bore_diameter_mm']) for r in csv.DictReader(open('data/bore-baseline-100.csv'))]
lo = 11.9850
counts = [0]*18
for v in x:
    counts[min(int((v - lo)/0.0025), 17)] += 1
for i, c in enumerate(counts):
    print(f"{lo + 0.0025*i:.4f}-{lo + 0.0025*(i+1):.4f}  {'#'*c} {c}")
print('reference lines: LSL 11.975 | nominal 12.000 | USL 12.025')
```

Expected picture: single right-shifted mound spanning 11.9849–12.0293; exactly one
bore past USL; the nominal line 12.000 sits left of center — the distribution floats
+9.8 um above it with real spread.

## Part D — Save the receipt (10 min)

Minitab: File > Save Project As > `module08-lab.MPX`; export the session window to
`module08-session.txt`. python3 mirror of the replay property: the court script
(exit 0) plus the seed statement in `MANIFEST.md` — same contract, same output.

## Gate

- [ ] Part A table reproduced (4-dp agreement)
- [ ] Part B court exits 0
- [ ] Part C histogram shows 0/100 outside spec, mean visibly right of nominal
- [ ] Part D project + session export saved (or court output pasted as the receipt)
