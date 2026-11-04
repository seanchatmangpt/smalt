# Module 02 — Solution Key

Every number below re-derives from the module's own CSVs. Receipts: commands
were run from the curriculum root
(`/Users/sac/smalt/docs/dmedi-bb-curriculum`) with `python3 - <<EOF` heredocs;
all exited 0. The script is reproduced verbatim so every figure is replayable.

## Re-derivation script (verbatim)

```python
import csv, statistics as st
from statistics import NormalDist

# ---- CTQ-1 defect stream: bore-inspection-dpmo.csv ----
rows = list(csv.DictReader(open('modules/02-define-overview/data/bore-inspection-dpmo.csv')))
n = len(rows)
U = sum(int(r['units_inspected']) for r in rows)
D = sum(int(r['defects_found']) for r in rows)
DPU = D / U
DPMO1 = D / (U * 1) * 1e6
DPMO6 = D / (U * 6) * 1e6
DPO = D / (U * 6)
z = NormalDist().inv_cdf(1 - DPO)
sig_level = z + 1.5
print('rows', n, 'units', U, 'defects', D)
print('DPU', round(DPU, 5), 'DPMO(1 opp)', round(DPMO1, 1),
      'DPMO(6 opp)', round(DPMO6, 1))
print('DPO', round(DPO, 7), 'z', round(z, 3), 'sigma level', round(sig_level, 2))
print('sigma level (1 opp)', round(NormalDist().inv_cdf(1 - D / U) + 1.5, 2))

# ---- CTQ-2 lead time: order-lead-time.csv ----
rows2 = list(csv.DictReader(open('modules/02-define-overview/data/order-lead-time.csv')))
lt = [float(r['lead_time_days']) for r in rows2]
s = sorted(lt)
def pct(d, p):
    k = (len(d) + 1) * p; fl = int(k); fr = k - fl
    return d[fl - 1] + fr * (d[fl] - d[fl - 1])
over7 = sum(1 for v in lt if v > 7)
print('lead n', len(lt), 'mean', round(st.mean(lt), 2), 'median', round(st.median(lt), 2),
      'sd', round(st.stdev(lt), 2), 'min', min(lt), 'max', max(lt))
print('P90', round(pct(s, 0.9), 1), 'over 7d:', over7,
      f'({100 * over7 / len(lt):.1f}%)')
```

## Verified output (python3, exit 0)

```
rows 20 units 4048 defects 49
DPU 0.0121 DPMO(1 opp) 12104.7 DPMO(6 opp) 2017.5
DPO 0.0020175 z 2.875 sigma level 4.38
sigma level (1 opp) 3.75
lead n 40 mean 17.8 median 17.35 sd 4.35 min 9.1 max 26.3
P90 24.1 over 7d: 40 (100.0%)
```

## Keyed answers

1. DPU = 49 / 4048 = **0.01210** defects per unit (totals: 4,048 units, 49
   defects over 20 inspection days).
2. (a) 49 / 4048 x 1e6 = **12,104.7 DPMO** (1 opportunity). (b) 49 / (4048 x 6)
   x 1e6 = **2,017.5 DPMO** (6 opportunities: bore diameter, taper, Ra, chamfer,
   edge break, seating datum). Both describe the same 49 physical defects on the
   same 4,048 housings; DPMO divides by opportunities, so the denominator — the
   operational definition, not the process — is what changed.
3. DPO = 0.0020175; z = Phi^-1(0.9979825) = **2.875**; sigma level = 2.875 + 1.5
   = **4.38** (4.375 before rounding). (1-opportunity variant: DPO 0.012105,
   z 2.254, sigma level **3.75**.) Corrected 2026-11-04: the earlier key showed
   z 2.878 / 3.76 — module court re-derivation caught the rounding drift.
4. Median **17.35 d**, P90 **24.1 d**, over-target **40/40 = 100%**. The Y
   statement carries the median (robust center; the metric the running case pins
   at 18.4 d registry-level). P90 still matters because tail orders drive the
   customer promise; % over target matters because the target is a max, so a
   percent-in-breach framing is the honest gate metric. All three move together
   if the project works.
5. Lawful explanations: (a) sampling noise — the CSV is a 40-order sample of the
   same process the 18.4 d registry constant summarizes; (b) the process actually
   moved between registry capture and this sample. Here (a) applies: 17.8 vs 18.4
   is ordinary sample variation with sd 4.35 (se = 4.35/sqrt(40) = 0.69 d, so
   18.4 is well inside one standard error of the sample mean). You do not
   re-pin a registry constant from one sample.
6. "Unit cost moves from the $41.80 baseline to <= $30.00 x (1 - 5% ROS) = $28.50,
   measured per the tooling and billet operational definitions (OD-14, OD-15),
   by gate week W26." Note the ceiling is $28.50 — the $30.00 price is the input
   to the derivation, not the target (Module 06 pins the derivation; the $13.30
   gap decomposition is Module 06 worksheet 03).

## Receipts

- Command: `python3 - <<'EOF' ... EOF` with the script above, run from
  `/Users/sac/smalt/docs/dmedi-bb-curriculum` — exit 0; output block above is
  the captured result of that run (2026-11-04 session).
- Pinned constants consumed: RUNNING-CASE.md CTQ-2 (18.4 d baseline, <= 7 d
  target), CTQ-3 ($41.80 baseline); Module 06 README (allowable = $30.00 x 0.95
  = $28.50, gap $13.30); Module 07 `worksheets/02-operational-definitions.md`
  (OD-11, OD-14, OD-15).
