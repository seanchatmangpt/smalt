# Module 10 — Solution Key

Datasets (all regenerate byte-exact from stated seeds; the court verifies this first):
- `data/xbar-r-subgroups.csv` — seed 42011, 25 subgroups × 5 from
  `random.gauss(12.009, 0.007407)`, +0.015 mm planted mean shift in subgroups 18–20.
- `data/bore-baseline-100.csv` — seed 42008, 100 draws `random.gauss(12.009, 0.007407)`.
- `data/lead-defectives.csv` — seed 42012, 25 days, n ∈ {80,100,120}, Bernoulli p = 0.14
  (p = 0.30, days 17–19).

## Re-derivation script

```python
import csv, statistics
from math import sqrt

# X-bar/R
rows = list(csv.DictReader(open('data/xbar-r-subgroups.csv')))
means, ranges = [], []
for r in rows:
    v = [float(r[f'sample{i}']) for i in range(1, 6)]
    means.append(sum(v)/5); ranges.append(max(v)-min(v))
xbb = sum(means)/25; rb = sum(ranges)/25
A2, D3, D4, d2 = 0.577, 0.0, 2.114, 2.326
print('Xbb', round(xbb,4), 'Rbar', round(rb,4))
print('Xbar UCL', round(xbb+A2*rb,4), 'LCL', round(xbb-A2*rb,4), '| R UCL', round(D4*rb,4), 'LCL', round(D3*rb,4))
sig = rb/d2
print('sigma_hat', round(sig,6), '=', round(sig*1000,2), 'um | sigma_xbar um', round(sig/sqrt(5)*1000,3))
print('OOC(all limits):', [(i+1, round(m,4)) for i,m in enumerate(means) if m > xbb+A2*rb or m < xbb-A2*rb])
keep = [i for i in range(25) if not (18 <= i+1 <= 20)]
x2 = sum(means[i] for i in keep)/22; r2 = sum(ranges[i] for i in keep)/22
print('Phase I: Xbb', round(x2,4), 'Rbar', round(r2,4),
      'UCL', round(x2+A2*r2,4), 'LCL', round(x2-A2*r2,4), 'R UCL', round(D4*r2,4))
print('OOC(Phase I limits):', [(i+1, round(means[i],4)) for i in range(25)
      if means[i] > x2+A2*r2 or means[i] < x2-A2*r2])

# I-MR
x = [float(r['bore_diameter_mm']) for r in csv.DictReader(open('data/bore-baseline-100.csv'))]
mr = [abs(x[i]-x[i-1]) for i in range(1, len(x))]
mrb = sum(mr)/len(mr); m = sum(x)/len(x)
print('I: mean', round(m,4), 'MRbar', round(mrb,5),
      'UCL', round(m+2.66*mrb,4), 'LCL', round(m-2.66*mrb,4), 'MR UCL', round(3.267*mrb,5))
print('sigma_I', round(mrb/1.128,6))
print('I OOC:', [(i+1, x[i]) for i in range(len(x)) if x[i] > m+2.66*mrb or x[i] < m-2.66*mrb])
print('MR OOC (lag):', [(i+2, round(v,4)) for i, v in enumerate(mr) if v > 3.267*mrb])

# p-chart
d = list(csv.DictReader(open('data/lead-defectives.csv')))
ns = [int(r['orders_inspected']) for r in d]; late = [int(r['late_orders']) for r in d]
pbar = sum(late)/sum(ns)
print('pbar', round(pbar,4), '=', sum(late), '/', sum(ns))
for i, (n, p) in enumerate(zip(ns, late)):
    u = pbar + 3*sqrt(pbar*(1-pbar)/n); l = pbar - 3*sqrt(pbar*(1-pbar)/n); f = p/n
    if f > u or f < max(l, 0):
        print(' OOC day', i+1, 'n', n, 'late', p, 'frac', round(f,3), 'UCL', round(u,3))
print('day 19: frac', late[18]/ns[18], 'UCL', round(pbar+3*sqrt(pbar*(1-pbar)/ns[18]),3))
```

**Verified output** (python3, these exact CSVs):

```
Xbb 12.0116 Rbar 0.0191
Xbar UCL 12.0226 LCL 12.0006 | R UCL 0.0404 LCL 0.0
sigma_hat 0.008212 = 8.21 um | sigma_xbar um 3.672
OOC(all limits): [(19, 12.0278), (20, 12.0267)]
Phase I: Xbb 12.0097 Rbar 0.0192 UCL 12.0208 LCL 11.9986 R UCL 0.0406
OOC(Phase I limits): [(18, 12.022), (19, 12.0278), (20, 12.0267)]
I: mean 12.0098 MRbar 0.0077 UCL 12.0303 LCL 11.9893 MR UCL 0.02517
sigma_I 0.006829
I OOC: [(41, 11.9849)]
MR OOC (lag): [(10, 0.0268), (11, 0.0281), (23, 0.0386), (41, 0.0304)]
pbar 0.1516 = 388 / 2560
 OOC day 17 n 120 late 31 frac 0.258 UCL 0.25
 OOC day 18 n 120 late 38 frac 0.317 UCL 0.25
day 19: frac 0.24 UCL 0.259
```

## Run rules fired (court-verified)

- X-bar (all-data limits): T1 at 19, 20; T5 (2-of-3 beyond 2σ) ending at 19, 20, 21
  — subgroup 18 joins the special-cause window via T5 despite sitting inside the UCL.
- I-chart: T1 at 41; T6 (4-of-5 beyond 1σ, same side) ending at 12.
- p-chart: T1 at days 17, 18. No T2/T3/T5/T6 signals on any chart.

## Exercise answers

1. (i) X-bar/R (subgroups n=3 → constants for n=3: A2=1.023, D4=2.574, d2=1.693).
   (ii) I-MR. (iii) u-chart (errors per 100 reports = defects per constant unit of
   exposure; c-chart only if the exposure is literally one fixed inspection unit).
   (iv) p-chart (defectives, varying n).
2. Subgroups must isolate common-cause variation inside the group; a mixed-shift
   subgroup carries between-shift drift INSIDE the range, inflating R-bar, which
   inflates every limit (limits come from R-bar) and hides the drift on the X-bar
   chart. The same inflation corrupts sigma-hat = R-bar/d2.
3. A2 = 3/(d2·√n) = 3/(2.326 × 2.2361) = **0.577**: the X-bar limits are 3 sigma_xbar
   about the grand mean, with sigma_xbar estimated as R-bar/(d2√n).
4. X-bar: Xbb 12.0116 ± 0.577 × 0.0191 = 12.0226 / 12.0006; R: 0 to 2.114 × 0.0191 =
   0.0404. Test 1 breaches: subgroups **19 (12.0278)** and **20 (12.0267)**.
5. Removing confirmed special causes tightens the limits (R-bar and the window are
   no longer inflated): Xbb 12.0097, UCL drops 12.0226 → 12.0208, so subgroup 18
   (12.0220) — inside the inflated UCL by 0.0006 mm — now breaches. The all-data
   computation carries a **bias toward silence**: the very variation the chart must
   detect widens the limits used to detect it.
6. (i) Control limits (11.9893) describe the VOICE OF THE PROCESS; spec limits
   (11.975/12.025) are the customer's — never compare a point to both as if one
   implied the other. Obs 41 (11.9849) is below the LCL yet inside spec. (ii) A
   control signal licenses an investigation (OCAP), not a disposition: contain,
   find the assignable cause, then disposition by spec.
7. Either the day is common-cause noise that happened to land high, or it is the tail
   of the days 17–19 special-cause window that rule 1 alone missed. The deciding
   datum is the physical timeline (the known logistics event spanning days 17–19)
   — the chart does not carry the context; the OCAP does.
8. Sampling variation: sigma-hat from 22 residual subgroups is an estimate with its
   own uncertainty (R-bar-based, ~±10–15% at this sample size); 8.25 vs 7.407 is
   within that. Investigate if the Phase-I estimate stays inflated after confirmed
   causes are removed, or if the R chart itself signals (an unstable range invalidates
   the sigma estimate entirely).

## Consistency with the spine (coherence court)

- Phase-I Xbb = 12.0097 vs spine mu = 12.009 ✓ (all-data Xbb 12.0116 carries the
  planted shift — that is the lesson, not a defect).
- Phase-I sigma-hat = 8.25 um vs spine 7.407 um: within R-bar estimation error; the
  court asserts only the data-derived values, not equality with the pin.
- Baseline sample Cpk (module 08/09) = 0.68 vs spine 0.72 ✓.
