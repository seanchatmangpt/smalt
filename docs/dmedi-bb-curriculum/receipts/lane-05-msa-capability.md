# Lane 05 Receipt — Modules 11 (MSA) + 12 (Process Capability)

Standing: **ALIVE** — all keys executed this session, exit 0, real output captured.

## Subject

`/Users/sac/smalt/docs/dmedi-bb-curriculum/` — Lane 05 owned surfaces only:
`modules/11-msa/`, `modules/12-process-capability/`, MANIFEST rows, and the
four Lane 05 datasets in `data/`.

## Delivered (all files on disk, verified)

- `modules/11-msa/README.md` + `labs/gage-rr-anova.md` +
  `labs/attribute-agreement.md` + `keys/gage_rr_key.py` +
  `keys/attribute_key.py`
- `modules/12-process-capability/README.md` +
  `labs/capability-derivation.md` + `labs/non-normal-capability.md` +
  `keys/capability_key.py`
- `data/gage-rr-bore.csv` (seed 411), `data/attribute-inspectors.csv` (seed
  713), `data/cpk072-bore-subgroups.csv` (seed 512),
  `data/flatness-lognormal.csv` (seed 1203) — all MANIFEST-registered.

## Verification ladder (actual exits)

```
python3 modules/11-msa/keys/gage_rr_key.py        -> EXIT 0 (court asserts 10<=pctGRR<=30, ndc>=5)
python3 modules/11-msa/keys/attribute_key.py      -> EXIT 0 (asserts Insp1 kappa>0.6, Insp3 within<0.2)
python3 modules/12-process-capability/keys/capability_key.py -> EXIT 0 (ALL COURTS PASS)
```

Spine court: Cpk re-derived from raw measurements = **0.7200**; court asserts
|Cpk − 0.72| ≤ 0.005 → PASS. Stability court on the same raw data: 0 OOC
points on X̄ and R charts → PASS. Verdict-flip court on flatness: raw Ppk
0.87 marginal-pass vs Box-Cox 0.64 fail, Shapiro raw 1e-5 / transformed
0.888 → PASS.

## Key figures (re-derived, not remembered)

- Gage R&R: %GRR 13.97% (EV 12.74 / AV 5.73 / PV 99.02 of TV), ndc 9 →
  10–30% marginal band, verdict stated (OK for process analysis, not for
  part acceptance on the 50 um tolerance; %GRR-of-tolerance = 23.4%).
- Attribute: Insp1 κ 0.793 / Insp2 0.452 / Insp3 0.409 vs reference; Insp3
  within-inspector κ −0.04; false-accept/false-reject classes taught.
- Capability: Cp 1.12 / **Cpk 0.72** / Pp 1.32 / Ppk 0.84 on the spine
  dataset (σ_within = R̄/d₂ = 0.007407 mm, μ̄ = 12.009 mm).
- Non-normal: Box-Cox λ = −0.5701; PPM 4,665 (raw normal) vs 27,344
  (transformed) vs 33,333 observed — verdict flips marginal-pass → fail.

## Defects found in the substrate (pre-existing, not session-introduced)

1. **Spine pinned-sigma defect (CONFIRMED)**: RUNNING-CASE's pinned sigma
   4.17 um contradicts its own pinned Cpk 0.72 at mu 12.009 (0.016/(3×0.00417)
   = 1.28). Coherent pin: Cpk 0.72 at sigma 7.407 um. Documented in
   MANIFEST cross-module pins, module READMEs, and asserted in court code.
   Resolution decision (which constant moves) belongs to the coordinator /
   Lane 19 coherence court.
2. **Lane 04 chart drift (as-observed 2026-11-04 ~11:41)**:
   `data/xbar-r-subgroups.csv` gained a high shift in subgroups 19–20 after my
   first read; my key reports it without asserting (Lane 04 owns the file).
   If intentional (special-cause teaching), fine; if not, Lane 04 must fix —
   capability on it is not lawful while OOC.

## Boundaries

One canonical checkout; no worktrees. Lane 05 touched only its owned paths.
MANIFEST was restructured mid-flight by other lanes; my rows were re-applied
to the current format (modules table + datasets table + pins section).
