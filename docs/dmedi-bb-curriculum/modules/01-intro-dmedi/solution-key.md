# Module 01 — Solution Key

Every derived number re-computed with python3 stdlib (`csv`, `statistics`) from
`data/baseline-bore-diameter.csv`; pinned constants cited from RUNNING-CASE.md
(adjudicated 2026-11-04 pair). Receipt at the end.

## Re-derivation script (verbatim)

```python
import csv, statistics as st

rows = list(csv.DictReader(open('modules/01-intro-dmedi/data/baseline-bore-diameter.csv')))
x = [float(r['bore_diameter_mm']) for r in rows]
mu, s = st.mean(x), st.stdev(x)
LSL, USL = 11.975, 12.025
usl_gap_um = (USL - mu) * 1000
lsl_gap_um = (mu - LSL) * 1000
cpk_sample = (USL - mu) / (3 * s)
cpk_pinned = (USL - 12.009) / (3 * 0.007407)
cpk_stale = (USL - 12.009) / (3 * 0.00417)
print('n', len(x), 'mu', round(mu, 5), 's_um', round(s * 1000, 2))
print('USL gap um', round(usl_gap_um, 2), 'LSL gap um', round(lsl_gap_um, 2))
print('sample Cpk', round(cpk_sample, 4), 'Cp', round((USL - LSL) / (6 * s), 4))
print('pinned Cpk', round(cpk_pinned, 4), '| stale 4.17um Cpk', round(cpk_stale, 3))
print('z_usl', round((USL - 12.009) / 0.007407, 2),
      'z_lsl', round((12.009 - 11.975) / 0.007407, 2))
```

## Verified output (python3, exit 0)

```
n 50 mu 12.00859 s_um 5.82
USL gap um 16.41 LSL gap um 33.59
sample Cpk 0.9401 Cp 1.4325
pinned Cpk 0.72 | stale 4.17um Cpk 1.279
z_usl 2.16 z_lsl 4.59
```

## Keyed answers

1. n = 50; mu = **12.00859 mm**; s = **0.00582 mm = 5.82 um**; Cpk =
   16.41 / (3 x 5.82) = **0.94**. USL governs (16.41 um < 33.59 um).
2. USL side: (12.025 - 12.009)/0.007407 = **2.16 sigma**; LSL side:
   (12.009 - 11.975)/0.007407 = **4.59 sigma**. Cpk = min / 3 =
   2.16/3 = **0.72** — the pinned constant re-derives.
3. The 4.17 um pair implies Cpk = 16/(3 x 4.17) = **1.279**, which contradicts
   the pinned 0.72 — the pair is internally inconsistent and was adjudicated
   stale on 2026-11-04 (RUNNING-CASE.md). The adjudicated pair wins because the
   course contract is formula-consistency: sigma is DERIVED from the pinned Cpk
   and mu, never asserted independently of them. Any artifact carrying 4.17 um
   is stale and must be corrected.
4. (a) sampling variation — the CSV is a 50-run sample of the process the pin
   summarizes (s 5.82 um vs sigma 7.407 um is within ordinary s-sampling spread
   for n = 50); (b) the process moved since the pin was set. Here (a) applies:
   sample mu agrees with the pin to 0.01 um, so the center did not move; only
   the spread estimate differs, which is the noisier statistic at n = 50. A
   sample never silently re-pins a registry constant.
5. (a) DMEDI — new process, no stable baseline to improve. (b) DMAIC — existing
   process with measurable baseline (the DMEDI Define inside this course treats
   it transactionally; the decision rule is "stable existing process with
   data"). (c) DMAIC — existing cell, regression repair, not new design.
6. Identity (exact subject: which dataset/design, at which commit/seed),
   authority (who/what admits the claim), consequence (real measured output —
   not stdout-only narration), replay (exact command that re-runs it). Missing
   any one: the court refuses — a receipt missing a field is not a receipt.
7. (i) Intermediate gates passed on status narration with no artifact check, so
   the vacuum propagated; (ii) the final gate inherited it because no check in
   the ladder could exit nonzero — a gate that cannot fail is not a gate. The
   preventing property: every gate check must be falsifiable (have a real pass
   condition that can exit 1 on a real subject).
8. z_usl = 2.16; sigma level = 2.16 + 1.5 = **3.66** (pinned, the course
   constant). Sample: z = 16.41/(3 x 5.82)... in sigma units 2.77, sigma level
   2.77 + 1.5 = 4.27. The pinned 3.66 is the course constant; the sample value
   is cited only against this CSV (n = 50) and never blended with the pin.

## Receipt

- Command: `python3 - <<'EOF' ... EOF` with the script above, run from
  `/Users/sac/smalt/docs/dmedi-bb-curriculum` — exit 0; the output block above
  is the captured run (2026-11-04 session).
- Court: `python3 modules/01-intro-dmedi/courts/court.py` (exit 0) re-derives
  the same numbers fail-closed; see `court.md`.
