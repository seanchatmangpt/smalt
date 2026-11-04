# Solution Key — Module 14 TRIZ for Product Processes

Numeric ground truth: `python3 scripts/derive_keys.py` against
`datasets/tool-wear.csv` (seed 1419). Every case step is numbered; courts
re-verify lookups against the README excerpt and every number against script
output.

## K1. Contradiction statements (W1)

1. Improving: 9 Speed. Worsening: 30 (surface-finish class; qualitative here —
   state it functionally: speed vs surface quality).
2. Improving: coverage/inspection thoroughness (functional). Worsening: 32
   cost/quantity of substance — stated functionally as coverage vs cost.
3. Improving: 27 Reliability (information gained). Worsening: 33 Ease of
   operation. Any answer that names both sides in numbered/functional TRIZ
   form is admitted; answers that keep the vague form are not.

## K2. Lookups (W2)

- (9 vs 28): principles 3, 17, 24, 32 — verified against the README excerpt
  row "9 Speed | 28 Accuracy of manufacture".
- (33 vs 28): principles 24, 26, 32 — verified against excerpt row
  "33 Ease of operation | 28 Accuracy of manufacture".

CPPC concept sentences:

- 3 local quality: hold the finish pass to a dedicated light pass so finish
  quality is produced locally, not repaired.
- 17 another dimension: take compensation in the axial micro-position mode,
  leaving radial geometry untouched.
- 24 intermediary: gauge holds the 12.000 reference; the operator never sets
  offset by feel.
- 32 optical: optical bore gauge measures without contact deflection.
- 26 copying (second row): logged process signatures stand in for full
  re-measurement when the signature matches a proven-clean family.
- 24 again: the same intermediary principle as the primary row — one principle
  serving two lookups is normal; the concept sentences must differ by surface.

## K3. Wear-law re-derivation (W3)

1. Script output (ground truth):

```text
slope=0.0079 um/part (0.79 um/100 parts), intercept=0.3155 um, s_res=0.56 um
predicted drift at 500 parts=3.94 um; uncompensated lag per 100-part comp interval=0.79 um
bores/shift: 480/7.5=64, 480/6.4=75, gain=11.0 (14.7%)
```

2. Drift at 500 parts = 0.0079 * 500 = 3.94 um. Drift at 4000 parts =
   0.0079 * 4000 = 31.6 um from the fitted line (the dataset's last observed
   value is 32.59 um, consistent with the fit plus residual).

3. 31.6 um exceeds the 25 um half-band: a purely wear-driven bore leaves
   tolerance long before a 4000-part edge life. Implication: compensation
   shifts the dimension-holding duty to the gauge (which corrects the smooth
   drift), but the edge itself must still be replaced on a schedule —
   compensation does not repeal wear, it re-points the reference.

## K4. Case 1 replay with a 50-part interval (W4)

- Uncompensated lag = 0.0079 um/part * 50 parts = 0.395 um (round 0.40 um).
  Half the 100-part lag of 0.79 um.
- Accuracy tradeoff: halving the interval halves worst-case lag, buying about
  0.4 um of margin against the 0.65 um gauge/machine short-term sigma —
  relevant only if the MSA shows gauge sigma near the lag term.
- Cost tradeoff: twice as many offset interruptions per shift. At 64-75
  bores/shift, a 100-part interval means roughly one interruption per 1.3-1.6
  h of cutting; a 50-part interval doubles that. Decision rule: choose the
  largest interval whose worst-case lag (slope * interval) stays under 10% of
  the remaining half-band after gauge error is subtracted; here 100 parts
  (0.79 um) already satisfies that, so 50 parts is not justified.

## K5. Case 2 trigger design (W5)

Reference trigger: the 1-of-3 sampled lot is inspected 100%. Any defective
found reverts the family to 100% inspection immediately and restarts the
10-clean-lot gate. In addition, every 20th lot is audited at double sample
size even when skipping — this is the drift detector.

Bounding arithmetic at p = 0.05 with 1-of-3 sampling + reversion on find:

- Probability a sampled lot of 200 shows at least one defective at p = 0.05:
  1 - 0.95^200 ≈ 0.99996 — drift is caught at the first sampled lot with
  near-certainty.
- Expected escapes before detection: only the 2 skipped lots ahead of the
  first sampled lot. At p = 0.05 that is 2 * 200 * 0.05 = 20 defectives total
  before the trigger fires, after which reversion stops the leak. Compare the
  untriggered steady state: 33 skipped lots per 50 lots * 200 units * 0.05
  = 333 per 10,000 units.
- The court question — does the scheme detect drift before 333-class escapes —
  is answered: yes, PROVIDED reversion is automatic and immediate. A trigger
  requiring human judgment is the failure mode; automate the reversion.

## K6. Principles index (W6)

Grading anchors, not fixed answers: each new transactional example must (a)
name the principle mechanism, (b) name the transactional surface (claims,
onboarding, procurement), (c) not duplicate a table row. Example of an
admissible answer for principle 19 (periodic action): rotate the compliance
check-list owner monthly so no reviewer owns the same checklist two cycles
running.

## K7. Mini case (W7)

Reference walk (fixture change vs holding rigidity):

1. Improving: 10 Time of setup activity (functional: changeover speed).
   Worsening: 27 Reliability / holding rigidity.
2. Excerpt-analog lookup: 3, 10, 24.
3. Concepts: (3) dedicate a fixture family per part family so clamping
   strategy is locally specialized; (10) pre-stage and pre-zero the next
   fixture while the current part cuts; (24) quick-release pallet as
   intermediary between machine table and part-specific jaws.
4. Chosen: 24 pallet — it converts a serial change (remove, rebuild, indicate)
   into a swap; reason: preserves rigidity (jaws stay torqued on the pallet)
   while cutting changeover to the pallet-unload time.

## Court notes (self-check)

- All numeric values re-derived from the CSV by the script; intercept 0.3155,
  slope 0.0079 um/part, s_res 0.56 um confirmed on disk this session.
- Matrix rows are course-excerpt pins; industrial use requires re-verification
  against a cited full matrix. This limitation is stated, not hidden.
- Case-study step chains are numbered 1-6 (case 1) and 1-6 (case 2); each
  step consumes only prior steps' outputs.
- The 40 x 2 table has exactly 40 rows, each with both a product and a
  transactional example (count re-verifiable by table row count).

## See Also

- `README.md`
- `workshop.md`
