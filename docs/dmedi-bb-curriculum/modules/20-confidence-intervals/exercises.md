# Module 20 Exercises — Confidence Intervals

All exercises re-derive from `data/bore-30.csv` (seed 42190) and
`data/ci-trap-overlap.csv` (seed 42290) — both registered in
`datasets/MANIFEST.md`. Every number you report must come from an executed
computation (snippet in `keys/solution-key.md` or your own scipy code).
Run from the curriculum root:

```
python3 - <<'EOF'
import csv, math
import numpy as np
from scipy import stats
x = np.array([float(r["bore_mm"]) for r in csv.DictReader(
    open("modules/19-hypothesis-testing/data/bore-30.csv"))])
n = len(x); xb = x.mean(); s = x.std(ddof=1); se = s/math.sqrt(n)
for c in (0.90, 0.95, 0.99):
    lo, hi = stats.t.interval(c, n-1, loc=xb, scale=se)
    print(c, round(lo,4), round(hi,4))
EOF
```

1. **E1 — CI ladder.** From bore-30 (n = 30, x-bar = 12.0072, s = 0.0035,
   t(0.975, 29) = 2.045): compute the 90/95/99% intervals for the mean.
   Confirm the 95% interval is (12.0059, 12.0085) and state why the entire
   interval sitting above 12.000 is the Module 19 rejection seen from the
   estimation side.
2. **E2 — Width engineering.** Width = 2 * t * s/sqrt(n). Verify the 95%
   width 0.0026 mm; then state the n needed to halve it under the
   1/sqrt(n) law (n ~ 120) and explain why confidence level and s are not
   knobs you can turn.
3. **E3 — The overlap trap.** From `data/ci-trap-overlap.csv` (30 parts per
   spindle): compute each spindle's mean, s, and 95% CI; the overlap region
   and its % of the narrower CI (expect 36%); then the pooled 2-sample t
   and its p-value. Confirm CIs overlap AND p = 0.0437 < 0.05 — and write
   the one-sentence rule this kills ("overlapping CIs prove no
   difference").
4. **E4 — The difference CI decides.** Compute the 95% CI of the difference
   (pooled, df = 58): expect (0.0000, 0.0019), excluding 0. Explain why the
   difference CI is the lawful decider and the marginal CIs are not.
5. **E5 — The vice-versa case.** From `paired-feed.csv` (Module 21,
   seed 42192, 25 parts): the marginal 95% CIs before (12.0057, 12.0091)
   and after (12.0027, 12.0062) overlap heavily, yet the paired t = -6.92,
   p = 3.7e-7 rejects hard. Re-derive both marginal CIs and the paired
   difference CI (-0.0039, -0.0021) and explain the mechanism (pairing
   removes part-to-part variance).
6. **E6 — Dataset-law drill.** State in 3 sentences why seeds 42190/42290
   are written into the exercises and `datasets/MANIFEST.md` before any
   number is reported, tying the answer to the data-provenance law in
   `RUNNING-CASE.md`.
