# Lab — Attribute Agreement Analysis (inspector pass/fail)

Dataset: `data/attribute-inspectors.csv` — 3 inspectors × 2 trials × 50 parts,
binary pass/fail verdict vs a known-good reference (12 true defectives, 24%
defect rate). Seed 713 (numpy `default_rng(713)`).
Key: `python3 modules/11-msa/keys/attribute_key.py`.

## Why attribute systems get their own analysis

A variable gage has a sigma; an inspector has an *opinion*. Attribute MSA asks
three questions: (1) does the inspector match the reference (**validity**),
(2) does the inspector match themselves (**within-inspector repeatability**),
(3) do inspectors match each other (**between-inspector reproducibility**).
Kappa quantifies agreement after correcting for chance:

  kappa = (p_observed − p_chance) / (1 − p_chance)

Landis bands: < 0 poor · 0–0.20 slight · 0.21–0.40 fair · 0.41–0.60 moderate ·
0.61–0.80 substantial · 0.81–1.00 almost perfect.

## Key (re-derived from raw CSV)

| inspector | kappa vs reference (trial 1) | within-inspector kappa | false accept | false reject |
|---|---|---|---|---|
| Insp1 | **0.793** (substantial) | **0.802** | 1 | 3 |
| Insp2 | 0.452 (moderate) | 0.196 (slight) | 5 | 5 |
| Insp3 | 0.409 (moderate) | **−0.040** (poor) | 4 | 8 |
| pooled | 0.550 | — | 10 | 16 |

## Misclassification classes (the risk table)

- **False accept** (type II, escaped defect): inspector passes a defective
  part. Escapes to the customer. Insp2 is the worst contributor (5).
- **False reject** (type I, scrap): inspector fails good parts. Costs money,
  not customers. Insp3 has the most (8) *and* cannot repeat their own
  judgments — a different random retest would change their verdicts.

Teaching rule: when accuracy is modest, false accepts are *biased* by the
base rate — with only 12 defectives in 50, "always pass" scores 76% accuracy
and kappa = 0. This is exactly why kappa, not raw %agree, is the metric.

## Verdict (state it)

- **Insp1**: acceptable — substantial agreement with the reference and with
  themselves. Use as the reference trainer.
- **Insp2**: marginal — moderate validity but only slight self-consistency;
  retrain against a boundary-sample set (near-limit parts), re-measure.
- **Insp3**: **not acceptable** — fails both validity and repeatability
  (within-inspector kappa ≈ 0: their verdicts are effectively coin flips).
  Remove from release inspection, retrain, and re-run this study before any
  downstream defect-rate claim is trusted.

Downstream consequence: any p-chart/DPMO figure computed from this visual
inspection line (module 10 lead-defectives case) carries the inspectors'
error in it — the MSA order law applies to attribute data too.

## Court

```bash
python3 modules/11-msa/keys/attribute_key.py   # must exit 0
```
