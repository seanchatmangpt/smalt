# Module 08 Exercises

Answer from the session-window output of `data/bore-baseline-100.csv` only — no
re-computation beyond a calculator. Answers in `solution-key.md` (court-checked).

1. How many bores would you expect outside spec in a 100-part lot if the process were
   centered at 12.000 with this spread? Show the z arithmetic before the verdict.
2. What is the distance from the sample mean to the nearer spec limit, in units of
   StDev? Which limit binds?
3. The largest bore in the file is 12.0293 mm. Which spec limit is it closest to —
   and is it inside or outside?
4. Re-open the CSV, sort `bore_diameter_mm` ascending, and confirm the median Minitab
   reported is the average of rows 50 and 51. Which two values are they?
5. The IQR Minitab reports is 0.0087 mm. A teammate proposes using IQR instead of
   StDev in the capability ratio (USL − mu)/(3 s). Name the statistical objection.
6. A teammate screenshots the histogram into the gate deck instead of pasting the
   session window. Give the two-part objection (replay + audit).
7. If the process mean were shifted to 12.000 with the same s = 0.007417, compute the
   expected outside-spec fraction using the normal model and compare to the off-center
   case from Exercise 1.
8. Minitab's Q1 uses (n+1)p interpolation. Compute Q1 by hand for n = 100 (25.25th
   ordered value) and explain why the 4-dp view prints 12.0059.

## Answer availability

- Exercises 1–4: full answers in `solution-key.md` (numbers court-checked by
  `courts/court.py`).
- Exercises 5–8: discussion answers in `solution-key.md` §Exercise answers.
