# Module 08 — Solution Key

Dataset: `data/bore-baseline-100.csv` (seed 42008, `random.gauss(12.009, 0.007407)` —
the ADJUDICATED spine sigma, 2026-11-04 — 100 draws, rounded to 4 dp at generation;
that rounding is part of the data, so the key re-derives from the **CSV as stored**,
the same thing Minitab reads).

## Re-derivation script (run it; exit 0 expected)

```python
import csv, statistics, math
rows = list(csv.DictReader(open('data/bore-baseline-100.csv')))
x = [float(r['bore_diameter_mm']) for r in rows]
n = len(x); mean = sum(x)/n
s = statistics.stdev(x)                      # sample sd, n-1 (Minitab default)
srt = sorted(x)
def pct(d, p):                                # Minitab's (n+1)p interpolation
    k = (len(d)+1)*p; fl = int(k); fr = k-fl
    return d[fl-1] + fr*(d[fl]-d[fl-1])
q1, q3 = pct(srt,0.25), pct(srt,0.75)
LSL, USL = 11.975, 12.025
print('n', n, 'mean', round(mean,4), 'stdev', round(s,4))
print('min', min(x), 'max', max(x), 'range', round(max(x)-min(x),4))
print('Q1', round(q1,4), 'median', statistics.median(x), 'Q3', round(q3,4), 'IQR', round(q3-q1,4))
print('dist mean->USL (mm)', round(USL-mean,4), '= z', round((USL-mean)/s,2))
print('dist mean->LSL (mm)', round(mean-LSL,4), '= z', round((mean-LSL)/s,2))
print('max bore', max(x), 'vs USL z =', round((USL-max(x))/s,2))
oos = [v for v in x if v < LSL or v > USL]
print('bores outside spec:', oos)
print('sample Cpk', round(min(USL-mean, mean-LSL)/(3*s),4))
```

**Verified output** (python3, this exact CSV):

```
n 100 mean 12.0098 stdev 0.0074
min 11.9849 max 12.0293 range 0.0444
Q1 12.0059 median 12.00995 Q3 12.0146 IQR 0.0087
dist mean->USL (mm) 0.0152 = z 2.05
dist mean->LSL (mm) 0.0348 = z 4.69
max bore 12.0293 vs USL z = -0.58
bores outside spec: [12.0293]
sample Cpk 0.6824
```

(4-dp views; full precision mean = 12.009815 mm, s = 0.007417 mm.)

## Exercise answers

**a)** Spec width = 0.050 mm, so a centered process with this spread has
±0.025 mm = ±3.37 s of margin (0.025/0.007417). Expected outside-spec fraction =
2 × (1 − Φ(3.37)) ≈ **7.5e-4** — about 0.075 bores per 100-part lot, i.e. roughly one
scrap every ~13 lots even when centered: with a Cpk-0.72 process, spread alone is a
scrap generator, not just the mean offset.

**b)** Nearer limit is USL: (12.025 − 12.0098)/0.007417 = **2.05 s**. The LSL is
4.69 s away. Asymmetry caused purely by the +9.8 um mean offset.

**c)** The max bore 12.0293 mm is **already past USL** — it sits 0.58 s ABOVE 12.025,
the sample's one scrap part. This is the visible face of Cpk 0.68: the capability
arithmetic and the sorted column tell the same story.

**d)** n = 100 is even, so Minitab's median = mean of rows 50 and 51 of the sorted
column = (12.0097 + 12.0102)/2 = **12.00995 mm**. Confirmed against the Session
window value in the lesson.

**5)** IQR measures spread but is not on the sigma scale: capability ratios are defined
   against sigma because the normal model converts sigma to tail probability (±3s ≈
   99.73%). An IQR-based ratio has no probabilistic reading and no Minitab definition.
   If the data were non-normal you would transform (Box-Cox) or use a non-normal
   method (Module 12), not substitute IQR.

**6)** (i) Replay: a screenshot cannot be re-run; the session window (or the court
   script) re-derives the numbers identically for any reviewer. (ii) Audit: text
   output is greppable, diffable, and quoteable — a reviewer can check the exact
   StDev against the CSV; a picture must be re-typed by hand, which is where
   transcription errors enter.

**7)** Centered at 12.000 with s = 0.007417: z = 0.025/0.007417 = 3.37, two-sided
   outside-spec fraction = 2 × (1 − Φ(3.37)) ≈ 7.5e-4. At the measured mean the
   binding side alone (above USL) is ≈ 2.0e-2 — **~27x worse than centered**. Both
   centering AND variation reduction are needed; neither alone reaches Cpk 1.33.

**8)** Q1 position = 0.25 × (100 + 1) = 25.25th ordered value = x(25) +
   0.25 × (x(26) − x(25)) = 12.0058 + 0.25 × (12.0062 − 12.0058) = **12.00590**,
   which prints as 12.0059 at 4 dp. (x(25) = 12.0058, x(26) = 12.0062 in the sorted
   column; the court re-derives Q1 from the interpolation itself, not from this quote.)

## Cross-checks the courts should re-run

1. `wc -l data/bore-baseline-100.csv` → 101 (header + 100 rows).
2. Mean re-derivation exits 0 and prints 12.0098 exactly.
3. Exactly one bore lies outside spec in this file (12.0293 > USL 12.025; min 11.9849
   > LSL 11.975). The baseline sample now visibly shows what the spine's Cpk = 0.72
   claims: capability risk from centering AND spread, witnessed by a scrap part.
   Sample Cpk here = (12.025−12.009815)/(3×0.007417) = **0.68**, consistent with the
   spine's pinned 0.72 (sampling variation), which re-derives exactly at
   sigma = 7.407 um (ADJUDICATED 2026-11-04; see RUNNING-CASE.md / MANIFEST.md).
