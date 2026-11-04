# datasets/MANIFEST.md

Per RUNNING-CASE.md data provenance law: every dataset is synthetic, generated
with a STATED seed, registered here by its owning lane, and every solution key
re-derives from the raw CSV.

This file is the single registry for the DMEDI BB curriculum: dataset rows AND
module bundle registrations (consolidated 2026-11-04 from the former root
`MANIFEST.md`, which is now a pointer here).

## Module bundles

Each lane registers its module bundles here. Rows are lane-owned; the
coherence court (Lane 19) reads this section as the bundle index. Column
meanings: Bundle = file set under the module dir; Court = exit-checked
verifier; Pinned = RUNNING-CASE constants the bundle consumes or establishes.

| Module | Bundle | Court | Pinned constants consumed / established | Owner lane |
|---|---|---|---|---|
| 01-intro-dmedi | modules/01-intro-dmedi/ (slides-outline, lab, exercises, solution-key, court.md, courts/, data/) | modules/01-intro-dmedi/courts/court.py (exit 0 = 17 checks) | Baseline CSV verified against ADJUDICATED spine: mu 12.00859 mm agrees with pinned 12.009; sample s 5.82 um and sample Cpk 0.9401 taught as sampling variation vs pinned pair (0.72 @ 7.407 um) — NOT regenerated (CSV carries no stale 4.17). Pinned arithmetic: (12.025-12.009)/(3x0.007407)=0.72; stale 4.17 um implies 1.279 (negative check in court). Staleness sweep: unframed "4.17" fails the court. Zero-artifacts honesty case study encoded in Slide 5 + receipt-grammar checks | Lane 01 |
| 02-define-overview | modules/02-define-overview/ (README, slides-outline, lab, exercises, keys/solution-key, court.md, courts/, data/) | modules/02-define-overview/courts/court.py (exit 0 = 20 checks) | DPMO ladder: 4048 units/49 defects, DPU 0.01210, DPMO 12104.7 (1 opp) / 2017.5 (6 opp), z 2.875, sigma 4.38/3.75 (drift-corrected 2026-11-04: key carried 2.878/3.76); lead time n 40: mean 17.8, median 17.35, sd 4.35, P90 24.1, 40/40 over 7 d, SE 0.69 vs pinned 18.4 | Lane 01 |
| 03-charter-mgpp-risk-comms | modules/03-charter-mgpp-risk-comms/ (README, slides-outline via README timing, lab via exercises, worksheets/ 01-07, court.md, courts/, data/) | modules/03-charter-mgpp-risk-comms/courts/court.py (exit 0 = 29 checks) | ED: n 80, median 52.0, sd 16.5, 75/80 = 93.8% over 30 min; claims: 60/60 blank closed_date, mean 16.07, median 15.8, sd 4.88 (UNVERIFIED standing taught). Charter worksheets cite $28.50/$13.30, 2.16/4.59 sigma; MGPP $13.30 x 10000 = $133000/yr; risk rank R1>R2>R5>R4>R3 (prose rank drift caught by court, corrected) | Lane 01 |
| 06-target-costing | modules/06-target-costing/ (README, 4 worksheets, courts/) | modules/06-target-costing/courts/court.py (exit 0 = 19/19 checks) | CTQ-3: establishes $41.80 baseline teardown (7 lines), $28.50 = $30.00 price x (1-5% ROS), $13.30 gap, $27.09 future state, driver savings $14.71; consumes Cpk 0.72/1.33 | Lane 03 |
| 07-scorecards | modules/07-scorecards/ (README, 5 worksheets, courts/) | modules/07-scorecards/courts/court.py (exit 0 = 21/21 checks) | OD-1..OD-15 operational definitions; CTQ->Y->x hierarchies; MGPP traceability for gates W5/W9/W15/W21/W26; tie-outs to module 06 values | Lane 03 |
| 33-key-lean-concepts | modules/33-key-lean-concepts/ (slides-outline, lab, exercises, keys/, courts/, data/) | modules/33-key-lean-concepts/courts/court.py (exit 0 = 15/15) | CTQ-2: decomposes 18.4 d -> wait 17.6 + processing 0.77 = 18.37 d (pin within rounding); takt 220 s; mill bottleneck 1.85x takt; kanban path -> 5.27 d <= 7 d | Lane 14 |
| 34-lean-design | modules/34-lean-design/ (slides-outline, lab, exercises, keys/, courts/, data/) | modules/34-lean-design/courts/court.py (exit 0 = 16/16) | 26-wk program as process: 130 d = 92/23/15; FE 70.8% -> scenario F 107 d, 23 d saved; honest rework finding: 2-d peer review flow-negative unless <= 1.86 work-days | Lane 14 |
| 35-dfma | modules/35-dfma/ (slides-outline, lab, exercises, keys/, courts/, data/) | modules/35-dfma/courts/court.py (exit 0 = 21/21) | CTQ-3: gimbal teardown 37->17 parts (54.1%), 228.5->109.0 s (52.3%); $11.30 = 85.0% of Lane 03's $13.30 gap; residual $2.00 machining obligation | Lane 14 |
| 36-intro-reliability | modules/36-intro-reliability/ (slides-outline, lab, exercises, keys/, courts/, data/, scripts/) | modules/36-intro-reliability/courts/court.py (exit 0 = 22/22; dataset byte-identical replay checked in-court) | Reliability case: spine pair (MTBF 1200 h, B10 900 h) proven jointly consistent only under Weibull beta=6.2417, eta=1290.7 (bisection in court); allocation -> 1200.0 exact; A_sys 0.9962 = 33 h/yr; PM 617.7 h @ 1% risk | Lane 14 |
| 16-concept-selection-pugh-ahp | modules/16-concept-selection-pugh-ahp/ (README, slides-outline, lab, exercises, solution-key, court, scripts/, data/) | modules/16-concept-selection-pugh-ahp/scripts/derive_selection.py (exit 0 = 20/20 checks) | A pinned to ADJUDICATED spine pair (mu 12.009 mm, sigma 7.407 um -> pilot Cpk 0.72, s 7.51 um); Pugh divergence: iter-1 leader B (net +3) vs AHP winner D (0.2736); consolidation D2 ties B, escalated to data; AHP CR 0.0246; teaching matrix CR 0.5840 refused; dataset seed 1607, 120 obs, byte-reproducible sha256 8888e52f | Lane 07 |
| 04-voice-of-customer | modules/04-voice-of-customer/ (slides-outline, lab, exercises, solution-key, court.md, data/: kano-responses.csv + gen_kano.py + compute.py) | modules/04-voice-of-customer/data/compute.py (exit 0 = 29 checks) | Kano majority classes CTQ-1/2/3 M, CTQ-4/5/6 O, CTQ-7/8 A, CTQ-9/10 I (CTQ-10 = I is the regression-guarded row); CR1-CR9 paired ranks -> weights sum 1.0; forward contract: points100 18/20/9/16/13/11/7/4/2 (sum 100) consumed by module 05 | Lane 02 |
| 05-qfd | modules/05-qfd/ (slides-outline, lab, exercises, solution-key, court.md, data/: 7 CSVs + gen_qfd.py + court.py) | modules/05-qfd/data/court.py (exit 0 = 26 checks; re-runs module-04 court in-court) | Full house of quality: points100 sum 100; column totals EC 241/209/180/157/173/78, conservation 1038; roof 15/15 pairs, EC5 4 conflicts; targets-vs-baseline spine: Cpk 0.72 -> 1.33 via EC1 +/-0.008 mm at sigma 2.0 um (0.008/(3x0.0020)), lead 18.4 -> <=7 d, cost 41.80 -> <=28.50 (forwards to Lane 03 costing); transactional claims QFD weights 22/20/7/15/13/23, conservation 1265 | Lane 02 |
| 23-simple-regression | modules/23-simple-regression/ (README, slides/, labs/, exercises, keys/, courts, scripts/) | modules/23-simple-regression/scripts/derive_keys.py (exit 0; TSS witness, SST=SSR+SSE, sqrt(F)=\|t\|, slope recovers 0.42) | Tool life -> bore deviation (CTQ-1); fitted yhat = 1.6790 + 0.4216x, R2 0.9684, F(1,28) 857.98; residual s 1.665 um is a component family, NOT the spine sigma 7.407 um; seed 42301, data/regression-simple.csv 30 rows | Lane 10 |
| 24-multiple-regression | modules/24-multiple-regression/ (README, slides/, labs/, exercises, keys/, courts, scripts/) | modules/24-multiple-regression/scripts/derive_keys.py (exit 0; centered-TSS witness incl. Breusch-Pagan auxiliary, sqrt(F_drop)=\|t_coolant\|, planted coefs recovered) | Ra from speed/feed/coolant; R2 0.96374, F(3,32) 283.47; VIF speed 25.109 / feed 25.487 (planted collinearity), coolant insignificant (p 0.0955) driving the reduced-model F = 2.950; seed 42401, data/regression-multi.csv 36 rows | Lane 10 |
| 25-multi-vari | modules/25-multi-vari/ (README, slides/, labs/, exercises, keys/, courts, scripts/) | modules/25-multi-vari/scripts/derive_keys.py (exit 0; TSS witness, spine court counts and positional share re-derived from raw CSV) | Bore deviation families: positional 90.0% share (F 81.58, eta2 0.8908), spindle/temporal 0% (F 0.08/0.12); total s 7.566 um in spine 7.407um regime; seed 42501, data/multivari-bore.csv 45 rows | Lane 10 |
| 42-prototype-pilot | modules/42-prototype-pilot/ (slides-outline, lab, exercises, keys/solution-key, court.md, court.py, data/: pilot-bore-30day.csv + pilot-ra-daily.csv + pilot-scrap-daily.csv + gen_pilot.py + gen_scrap.py) | modules/42-prototype-pilot/court.py (exit 0 = 31 checks, incl. byte-identical generator replay) | Pilot lot 120 (min n = 117 from 1.5 − 1.645·sqrt(1/(9n) + 1.5²/(2(n−1))) ≥ 1.33); 30-day run n=1200: Cpk 1.481, LCB 1.429 ≥ 1.33; X-bar/R 240 subgroups (Xbb 12.0049, Rbar 0.0102, UCL 12.0108/11.9990, UCLR 0.0216), 0 rule-1; Ra I-MR stable (t = 0.459 < 2.101); scrap 5/4500 = 0.111% ≤ binomial critical X ≤ 14 (CP 95% upper 0.486%/0.513% at 14/15); ppm at Cpk 1.33 = 66.1; seeds 42016 | Lane 16 |
| 43-process-control | modules/43-process-control/ (slides-outline, lab, exercises, keys/solution-key, court.md, court.py) | modules/43-process-control/court.py (exit 0 = 16 checks, incl. wrong-constants mutation) | Control plan OP30 bore: sigma-hat = Rbar/d2 = 0.010217/2.326 = 0.004392 mm, PCR 1.897; limits inside specs; p-chart pbar 5/4500 = 0.001111, UCL 0.00927, LCL floored 0; day-1 (3/150 = 0.02 > UCL) rule-1 signal — aggregate exit passes while p-chart flags day 1; SPC handoff spec (X-bar/R, Ra I-MR, scrap p-chart; reactors/escalation); OCAP-BORE-01 format; DFMEA-linked rows (lane-11 register) | Lane 16 |
| 44-implementation-planning | modules/44-implementation-planning/ (slides-outline, lab, exercises, keys/solution-key, court.md, court.py) | modules/44-implementation-planning/court.py (exit 0 = 9 checks + live subprocess replays of 42/43 courts) | Roadmap weeks 16–26: prototype lot wk16 d1–3, pilot wk16.5–20.8 (16.5 + 30/7 = 20.8 ≤ gate 21; counterfactual wk17 start = 21.29 misses gate — proved in court), rollout 22–24, training 21–24 (20 slots), audit 24–26, handoff wk26; 7-item closing-the-loop checklist exit-checked on disk (Module 11 MSA cross-lane loud-PENDING if unlanded); consumes CLD-01 adjudicated pair (Cpk 0.72 / sigma 7.407 um) | Lane 16 |
| 26-design-fmea | modules/26-design-fmea/ (slides-outline, scales-anchored, exercises, solution-key, data/dfmea-worksheet.csv + scripts/gen_dfmea.py, scripts/derive_keys.py) | modules/26-design-fmea/scripts/derive_keys.py (exit 0 = 109 checks; re-derives every RPN S×O×D, all 12 ranks w/ severity-desc + mode_id tiebreak, AP classes via documented severity-first table, S/O/D ranges, no-post-worse-than-pre) | DFMEA gimbal boring op: 12 failure modes FM-01..FM-12, actions DC-01..DC-12; top rank FM-01 tool-wear oversize RPN 360 (10/6/6) → post 90 (AP stays High: S=10 never de-escalates); computed RPN-vs-AP teaching split: FM-09 S=4 RPN 224 outranks FM-05 S=9 RPN 216; ANCHORED scales (S: 3=cosmetic Ra drift … 10=scrap+shipment escape; O: PPM bands citing tool-wear.csv/deburr/ramp-up logs; D: named controls, unnameable ⇒ D≥7); actions trace to Lane 06 TRIZ C1-C8 (C8/C4 parked w/ feasibility) and forward to pinned DOE factors (spindle speed, feed, coolant %, coating); FM-12 flagged PFMEA boundary | Lane 11 |
| 27-detailed-design | modules/27-detailed-design/ (slides-outline, data/design-control-checklist.csv, scripts/derive_keys.py) | modules/27-detailed-design/scripts/derive_keys.py (exit 0 = 18 checks; tolerance math re-derived from pinned constants in BOTH regimes + linkage court DFMEA↔checklist) | Detailed design: 18-row design-control checklist CP-1..CP-18 mapping DC-01..DC-12 (+6 documented additions DC-02b/04b/07b/10b/13/13b) → controls → verification + acceptance → DFX classes (DFM/DFA/DFT/meas/poka all exercised); guard-band derivation: EC1 ±0.008 mm (matches module 05 pin) inside ±0.025 spec; sigma_max = 0.008/(3×1.33) = 2.01 um; baseline Cpk vs guard band 0.64 (pinned 4.17 um) / 0.36 (adjudicated spine 7.407 um); DOE must deliver 2.08× (4.33× variance) or 3.69× (13.6×) sigma reduction; Cpk-vs-spec 1.28 (mu 12.009, MANIFEST cross-note) vs 2.00 centered = centering action split | Lane 11 |
| 08-intro-minitab | modules/08-intro-minitab/ (README, slides-outline, lab, exercises, solution-key, courts/) | modules/08-intro-minitab/courts/court.py (exit 0 = 3 dataset-regen + 24 numeric checks) | Consumes adjudicated spine pair (mu 12.009, sigma 7.407 um); bore-baseline-100 sample: mean 12.0098, s 0.007417, exactly 1 OOS bore (12.0293), sample Cpk 0.68 vs pinned 0.72 (sampling variation); datasets regenerate byte-exact from seeds 42008/42011/42012 in-court | Lane 04 |
| 09-basic-statistics | modules/09-basic-statistics/ (README, slides-outline, lab, exercises, solution-key, courts/) | modules/09-basic-statistics/courts/court.py (exit 0 = 1 dataset-regen + 16 numeric checks) | Same bore sample: Tukey fences 11.9928/12.0277, 4 fence flags (12.0293 also OOS), normal probes (centered LSL tail 3.65e-4, measured USL tail 2.01e-2), CLT sim seeds 42009/42010 | Lane 04 |
| 10-variation-control-charts | modules/10-variation-control-charts/ (README, slides-outline, lab, exercises, solution-key, courts/) | modules/10-variation-control-charts/courts/court.py (exit 0 = 3 dataset-regen + 37 numeric checks incl. run rules) | Chart-selection decision tree (flagship); X-bar/R n=5 (Xbb 12.0116 all-data / 12.0097 Phase-I = spine mu, limits 12.0226/12.0006 -> 12.0208/11.9986, R UCL 0.0404/0.0406, sigma-hat 8.21/8.25 um); planted shift subgroups 18-20 signals T1@19,20 + T5@21 all-data, all three breach Phase-I limits; I-MR (mean 12.0098, MRbar 0.0077, limits 12.0303/11.9893, MR UCL 0.02517, T1@41, T6@12); p-chart pbar 0.1516, variable UCLs 0.250/0.259/0.272, OOC days 17-18, day 19 in-control (0.240 vs 0.259) | Lane 04 |
| 11-msa | modules/11-msa/ (README, labs/, keys/: attribute_key.py + gage_rr_key.py) | modules/11-msa/keys/gage_rr_key.py (exit 0; ANOVA Gage R&R re-derivation, 4 band asserts) + replayed by modules/45-capstone-brief/court.py | Seed 411 crossed Gage R&R (10x3x3); %GRR 13.97 / ndc 9 in the 10-30% conditional band; K 5.15 cancels in %Study Var ratios; consumes 50 um tolerance framing | Lane 05 |
| 12-process-capability | modules/12-process-capability/ (README, court.py, labs/, keys/capability_key.py) | modules/12-process-capability/court.py (exit 0 = 19 checks; stale 4.17 um refused) | Re-derives mu 12.0090 mm / sigma_within 7.407 um / Cp 1.12 / Cpk 0.72 / Pp 1.32 / Ppk 0.84 from data/cpk072-bore-subgroups.csv (seed 512); in-control stability proof | Lane 05 |
| 13-concept-generation | modules/13-concept-generation/ (README, workshop.md, exercises.md, solution-key.md, datasets/, scripts/score_concepts.py) | modules/13-concept-generation/scripts/score_concepts.py (exit 0; deterministic weighted scoring 0.4N+0.6F re-derived) | Seed 1317 raw-idea funnel counts; C1 4.20 top, C8 2.60 killed; consumes charter MGPP framing | Lane 06 |
| 14-triz-product | modules/14-triz-product/ (README, workshop.md, exercises.md, solution-key.md, datasets/tool-wear.csv, scripts/derive_keys.py) | modules/14-triz-product/scripts/derive_keys.py (exit 0; slope/intercept/s_res + lag & cycle-time keys re-derived) | Seed 1419 tool-wear 40 rows; wear slope 0.79 um/100 parts, s_res 0.56 um; drift 32.59 um at 4000 parts vs 25 um half-band | Lane 06 |
| 15-triz-transactional | modules/15-triz-transactional/ (README, workshop.md, exercises.md, solution-key.md, datasets/onboarding-durations.csv, scripts/derive_keys.py) | modules/15-triz-transactional/scripts/derive_keys.py (exit 0; serial vs parallel stage keys re-derived) | Seed 1511 onboarding 12 hires x 5 stages; serial mean 11.1 d vs parallel 7.1 d (P90 12.6/8.5) | Lane 06 |
| 17-statistical-tolerance | modules/17-statistical-tolerance/ (README, court.py) | modules/17-statistical-tolerance/court.py (exit 0 = 33 checks; stale 4.17 um refused) | WC [-28,+30] um FAIL, RSS sigma 5.000 um Cpk 1.60, MC Cpk 1.588 (seed 20261104), reconciliation band, allocation k 0.8276 / lambda 0.2727; consumes gimbal-bore-stack-parameters.csv | Lane 08 |
| 18-monte-carlo | modules/18-monte-carlo/ (README, exercises.md, keys/solution-key.md, scripts/mc_bore_stack.py) | modules/18-monte-carlo/scripts/mc_bore_stack.py (exit 0; 1k/5k/10k ladder re-derived) | Seeds 20261104 (registered) / 20261105 (re-derivation run); 10k Cpk 1.588, 0 exceedances; consumes datasets/gimbal-bore-stack-parameters.csv + datasets/monte-carlo-bore-stack-summary.csv | Lane 08 |
| 19-hypothesis-testing | modules/19-hypothesis-testing/ (README, decision-tree.md, key.md, COURT-RECEIPT.md, court.py, data/bore-30.csv) | modules/19-hypothesis-testing/court.py (exit 0; all reported statistics re-derived from raw CSV) | Seed 42190 bore-30 n=30; one-sample t vs pinned mu 12.009 | Lane 09 (unverified) |
| 20-confidence-intervals | modules/20-confidence-intervals/ (README, key.md, court.py, data/ci-trap-overlap.csv) | modules/20-confidence-intervals/court.py (exit 0 = 18 checks; CI-overlap trap: overlap AND p=0.0437 reject) | Seed 42290 ci-trap-overlap n=30; CI overlap vs two-sample t teaching trap | Lane 09 (unverified) |
| 21-testing-means-medians-variances | modules/21-testing-means-medians-variances/ (README, key.md, court.py, data/: coating-ab-bore + coolant-anova + paired-feed CSVs) | modules/21-testing-means-medians-variances/court.py (exit 0 = 46 checks incl. group-corruption mutation + stale-4.17 sweep) | Seeds 42191/42192/42193; pooled+Welch t, paired t, Levene/Bartlett, Mann-Whitney, one-way ANOVA + pairwise CIs | Lane 09 (unverified) |
| 22-proportion-chi-square | modules/22-proportion-chi-square/ (README, key.md, court.py, data/: bore-100-gof + cnc-ab + defect-machine + scrap-shifts CSVs) | modules/22-proportion-chi-square/court.py (exit 0 = 28 checks incl. wrong-n mutation) | Seeds 42194-42197; 1-prop z, 2-prop z, chi-square independence + GOF | Lane 09 (unverified) |
| 28-2way-anova | modules/28-2way-anova/ (README, court.py, keys/solution-key.md, lab-interaction-plot.md, data/anova-2way.csv) | modules/28-2way-anova/court.py (exit 0 = 33 checks; stale 4.17 um refused) | Seed 28; 3 machines x 2 coatings x 6 reps; F_A 4.63 / F_B 9.61 / F_AB 58.63, SS_total 0.000686 mm^2 exact closure | Lane 12 |
| 29-intro-doe | modules/29-intro-doe/ (README, keys/solution-key.md) | keys/solution-key.md inline python3 -c receipts (exit 0; conceptual module, no dataset, no RNG) | No dataset; consumes spine framing (0.5/7.407 error-df example); run-count arithmetic 2^4 x 3 = 48 runs, 45 df | Lane 09 (unverified) |
| 30-full-factorial-doe | modules/30-full-factorial-doe/ (README, court.py, keys/solution-key.md, data/doe-2k-full.csv) | modules/30-full-factorial-doe/court.py (exit 0 = 33 checks incl. wrong-constant mutation + stale-4.17 sweep) | Seed 30; 2^3 x 2 reps; A +12 um / B +8 um / AB -6 um; holdout +++/-- prediction PIs | Lane 12 |
| 31-fractional-factorial-doe | modules/31-fractional-factorial-doe/ (README, court.py, solution-key.md, data/fractional-2k5-2.csv) | modules/31-fractional-factorial-doe/court.py (exit 0 = 34 checks incl. wrong-generator mutation + stale-4.17 sweep) | Seed 43108; 2^(5-2) res III design, defining-group closure, fold-over to res IV | Lane 09 (unverified) |
| 32-catapult-simulation | modules/32-catapult-simulation/ (README, court.py, solution-key.md, data/catapult-results.csv + simulator.py) | modules/32-catapult-simulation/court.py (exit 0 = 25 checks; sha256 pinned) | Seed 43201; 16+4 split, 15 contrast means, curvature t=-9.86 | Lane 09 (unverified) |
| 37-doe-curvature | modules/37-doe-curvature/ (slides-outline, exercises, courts/court.py, data/compute.py + bore-curvature.csv) | modules/37-doe-curvature/courts/court.py (exit 0 = 20 checks; deterministic regen in-court) | Seed 37001; 2^3 + 6 center points; center-point curvature vs 2^3 factor model | Lane 15 |
| 38-conjoint | modules/38-conjoint/ (slides-outline, exercises, courts/court.py, data/compute.py + conjoint-cards.csv + conjoint-ranks.csv) | modules/38-conjoint/courts/court.py (exit 0 = 26 checks) | Seeds: authored L9 card design (no RNG) + 38001 rank draws; true part-worths u_price/u_lead/u_tol/u_finish | Lane 15 |
| 39-mixture-designs | modules/39-mixture-designs/ (slides-outline, exercises, courts/court.py, data/compute.py + coolant-mixture.csv) | modules/39-mixture-designs/courts/court.py (exit 0 = 26 checks) | Seed 39001; {3,2} simplex lattice + centroid, 2 reps/point; quadratic blend terms | Lane 15 |
| 40-robust-design | modules/40-robust-design/ (slides-outline, exercises, courts/court.py, data/compute.py + robust-bore.csv) | modules/40-robust-design/courts/court.py (exit 0 = 43 checks) | Seed 40001; L8 inner x 2^2 outer (32 runs); S/N ratios, bore dev + tool life responses | Lane 15 |
| 41-helicopter-rsm-lab | modules/41-helicopter-rsm-lab/ (slides-outline, exercises, courts/court.py, data/compute.py + helicopter-rsm.csv) | modules/41-helicopter-rsm-lab/courts/court.py (exit 0 = 43 checks) | Seed 41001; 16-run 2^(7-3) res IV screen + steepest ascent + rotatable CCD (a=2); median-of-3 drops | Lane 15 |
| 45-capstone-brief | modules/45-capstone-brief/ (capstone-brief, capstone-workbook, phase-gate-checklist, scoring-rubric, worked-example-measure.md, court.py) | modules/45-capstone-brief/court.py (exit 0 = 40 checks; %GRR 13.97 / ndc 9 + mu 12.0090 / sigma 7.407 um / Cpk 0.72 re-derived from raw CSVs; mutation-rejected; stale 4.17 um sweep) | Adjudicated spine pair (mu 12.009 mm, sigma 7.407 um, Cpk 0.72) re-derived independently from data/gage-rr-bore.csv (seed 411) + data/cpk072-bore-subgroups.csv (seed 512); %GRR 10-30% conditional band, ndc >= 5; target Cpk 1.33 NO-verdict lawful | Lane 16 (registry-completion pass, 2026-11-04) |

Court re-run commands migrated from the former root MANIFEST.md (all exit 0;
44 replays 42 and 43 in-court; Lane 04 datasets regenerate byte-exact
in-court):

```
python3 modules/06-target-costing/courts/court.py
python3 modules/07-scorecards/courts/court.py
python3 modules/42-prototype-pilot/court.py
python3 modules/43-process-control/court.py
python3 modules/44-implementation-planning/court.py
python3 modules/08-intro-minitab/courts/court.py
python3 modules/09-basic-statistics/courts/court.py
python3 modules/10-variation-control-charts/courts/court.py
```

Dataset-row content from the former root MANIFEST.md, migrated/deduped
2026-11-04: the Lane 15 planted-structure rows (modules 37-41 CSVs) are
covered by the GAP-5 seal table below (seeds 37001/38001/39001/40001/41001);
unique planted-structure detail preserved here:

- `modules/37-doe-curvature/data/bore-curvature.csv` — 2^3 factorial (2 reps/corner) from gauss(9.0-2.2A+1.4B+0.9C+1.1AB+2.55, 2.5) + 6 center points gauss(5.6, 2.5), rounded 2 dp; 22 x 7 cols
- `modules/38-conjoint/data/conjoint-cards.csv` — deterministic L9 orthogonal array, 4 attrs x 3 levels with true part-worths u_price/u_lead/u_tol/u_finish + u_total; 9 x 10 cols
- `modules/38-conjoint/data/conjoint-ranks.csv` — rank = order of true utility + gauss(0, 0.55); rank 1 = most preferred; 9 x 2 cols
- `modules/39-mixture-designs/data/coolant-mixture.csv` — {3,2} simplex lattice + centroid, 2 reps/point, gauss(12x1+6x2+2x3+22x1x2-4x1x3+3x2x3, 0.8), rounded 2 dp; 14 x 6 cols
- `modules/40-robust-design/data/robust-bore.csv` — L8 inner x 2^2 outer (32 runs), bore dev gauss(true_dev, 1.0) + tool life gauss(true_life, 2.0) (see data/compute.py); 32 x 8 cols
- `modules/41-helicopter-rsm-lab/data/helicopter-rsm.csv` — 16-run 2^(7-3) res IV screen + steepest ascent + rotatable CCD (a=2, 3 factors); response = median of 3 gaussian drops; 39 x 15 cols

The root's Lane 04 dataset rows (`data/bore-baseline-100.csv` seed 42008,
`data/xbar-r-subgroups.csv` seed 42011, `data/lead-defectives.csv` seed
42012) were duplicates of the recovered rows below — deduped, checksums
block is authoritative.

| Dataset | Owning lane/module | Seed | Shape | Planted structure | Key location |
|---|---|---|---|---|---|
| `modules/28-2way-anova/data/anova-2way.csv` | Lane 12 / Module 28 | python3 `random`, seed 28 | 3 machines x 2 coatings x 6 reps = 36 rows | machine x coating interaction (coated helps M1/M2, hurts M3), within-cell N(0, 2 um) | Module 28 README section 4 (ANOVA table: F_A=4.63, F_B=9.61, F_AB=58.63, SS_total=0.000686 mm^2) |
| `modules/30-full-factorial-doe/data/doe-2k-full.csv` | Lane 12 / Module 30 | python3 `random`, seed 30 | 2^3 full factorial x 2 reps = 16 rows | A(speed) +12 um, B(feed) +8 um, AB -6 um, C=0, N(0, 1.5 um) | Module 30 README sections 2-7 (effects, half-normal, prediction equation, holdout confirmations) |
| `modules/13-concept-generation/datasets/concept-portfolio.csv` | Lane 06 / Module 13 | n/a (judged scores; seed 1317 for raw-idea funnel counts only) | 8 concepts x (novelty 1-5, feasibility 1-5) | deterministic weighted scoring 0.4N+0.6F | `modules/13-concept-generation/scripts/score_concepts.py` (C1 4.20 top; C8 2.60 killed) |
| `modules/14-triz-product/datasets/tool-wear.csv` | Lane 06 / Module 14 | python3 `random`, seed 1419 | 40 rows: parts 100..4000, drift um (2 dp); drift 0.8 um/100 parts + N(0, 0.6) | wear slope 0.79 um/100 parts, s_res 0.56 um; drift 32.59 um at 4000 parts exceeds the 25 um half-band | `modules/14-triz-product/scripts/derive_keys.py` (slope/intercept/s_res; lag & cycle-time keys) |
| `modules/15-triz-transactional/datasets/onboarding-durations.csv` | Lane 06 / Module 15 | python3 `random`, seed 1511 | 12 hires x 5 stage durations (0.1 d), stage means 3.1/2.4/1.8/2.2/1.5 d x U(0.7,1.4) | serial mean 11.1 d vs parallel-lane mean 7.1 d (P90 12.6/8.5) | `modules/15-triz-transactional/scripts/derive_keys.py` |
| `datasets/gimbal-bore-stack-parameters.csv` | Lane 08 / Modules 17-18 | n/a (parameters, not draws) | 4 rows: contributor x (mean um, tol um, cost weight) | CPPC gimbal bore stack (bore dia / thermal / fixture / deflection), net mean +1 um | `modules/18-monte-carlo/scripts/mc_bore_stack.py` + Module 17 README |
| `datasets/monte-carlo-bore-stack-summary.csv` | Lane 08 / Module 18 | python3 `random`, seed 20261104 | 3 rows: 1k/5k/10k ladder (P0.13/P50/P99.87, mu, sigma, exceed, Cpk) | additive normal stack, sigma_i = tol/3; 10k Cpk 1.588, 0 exceedances | `python3 modules/18-monte-carlo/scripts/mc_bore_stack.py` (exit 0) |

| `modules/04-voice-of-customer/data/kano-responses.csv` | Lane 02 / Module 04 | python3 `random`, seed 20261104 | 120 rows x 5 cols (10 Kano attributes K-01..K-10 x 12 respondents) | Kano pair draws per authored class table: K-01/02/03 M, K-04/05/06 O, K-07/08 A, K-09/10 I (majority rule); K ids are Kano-attribute namespace, distinct from spine CTQ-1/2/3 | `modules/04-voice-of-customer/data/compute.py` (exit 0; 29/29 checks) |
| `modules/05-qfd/data/qfd-cppc-weights.csv` | Lane 02 / Module 05 | n/a (authored design data; deterministic writer) | 9 rows x 8 cols (kano_id + spine_ctq derivation columns); points100 sum exactly 100 | largest-remainder allocation of module-04 paired ranks: CR1..CR9 = 18/20/9/16/13/11/7/4/2 | `modules/05-qfd/data/court.py` (exit 0) |
| `modules/05-qfd/data/qfd-cppc-matrix.csv` | Lane 02 / Module 05 | n/a (authored) | 9 rows x 7 cols, cells {1,3,9} | row sums 15/11/4/12/9/11/10/2/2; weighted column totals EC1 241, EC2 209, EC3 180, EC4 157, EC5 173, EC6 78; conservation 1038 | `modules/05-qfd/data/court.py` |
| `modules/05-qfd/data/qfd-cppc-roof.csv` | Lane 02 / Module 05 | n/a (authored) | 15 rows = C(6,2) | EC5 most-conflicted (4 negatives incl. EC1--EC5 --) | `modules/05-qfd/data/court.py` |
| `modules/05-qfd/data/qfd-cppc-targets.csv` | Lane 02 / Module 05 | n/a (authored) | 6 rows x 5 cols | spine constants: lead 18.4 -> <=7 d; cost 41.80 -> <=28.50; EC1 +/-0.008 mm at sigma 2.0 um => Cpk 1.33 (0.008/(3x0.0020)) | `modules/05-qfd/data/court.py` |
| `modules/05-qfd/data/qfd-claims-weights.csv` | Lane 02 / Module 05 | n/a (authored) | 6 rows x 4 cols | direct-rating normalized 22/20/7/15/13/23 (sum 100) | `modules/05-qfd/data/court.py` |
| `modules/05-qfd/data/qfd-claims-matrix.csv` | Lane 02 / Module 05 | n/a (authored) | 6 rows x 7 cols | column totals T1 250, T2 259, T3 147, T4 204, T5 138, T6 267; conservation 1265 | `modules/05-qfd/data/court.py` |
| `modules/05-qfd/data/qfd-claims-roof.csv` | Lane 02 / Module 05 | n/a (authored) | 15 rows = C(6,2) | T1--T3 and T2--T3 both -- (rework loops = transactional constraint) | `modules/05-qfd/data/court.py` |

Recovered rows (Lane 02 session: present in an earlier registry revision, dropped
when the registry was rewritten by a concurrent lane; CORRECTED 2026-11-04, BB-19
row D7: the rows below previously carried PRE-ADJUDICATION generator params
(sigma 0.00417 mm, no planted shift) that could not re-derive the on-disk CSVs.
The on-disk files were regenerated post-adjudication by the BB-04r retry lane at
the adjudicated spine sigma 0.007407 mm; seeds unchanged. Re-derivation verified
byte-exact via modules 08/09/10 courts/court.py (all exit 0, 2026-11-04)):

| Dataset | Owning lane/module | Seed | Shape | Planted structure | Key location |
|---|---|---|---|---|---|
| `data/bore-baseline-100.csv` | Module 04 wave (pre-Lane-02); regenerated post-adjudication 2026-11-04, BB-04r | 42008 | 100 obs x 2 cols | random.gauss(12.009, 0.007407), rounded 4 dp | modules 08, 09, 10 (I-MR) |
| `data/xbar-r-subgroups.csv` | Module 04 wave (pre-Lane-02); regenerated post-adjudication 2026-11-04, BB-04r | 42011 | 25 subgroups x 5 draws | random.gauss(12.009, 0.007407), rounded 4 dp, + 0.015 mm planted shift in subgroups 18-20 | module 10 (X-bar/R) |
| `data/lead-defectives.csv` | Module 04 wave (pre-Lane-02); regenerated post-adjudication 2026-11-04, BB-04r | 42012 | 25 x 3 cols | per day: n in {80,100,120}, Bernoulli(p=0.14; p=0.30 days 17-19 special-cause window) | module 10 (p-chart) |

Rows added 2026-11-04 (BB-19 row D7 sweep: registered-but-unlisted regenerated
datasets; params re-derive their CSVs byte-exact via the cited generators):

| Dataset | Owning lane/module | Seed | Shape | Planted structure | Key location |
|---|---|---|---|---|---|
| `modules/16-concept-selection-pugh-ahp/data/concept_trials.csv` | Lane 07 / Module 16; regenerated post-adjudication 2026-11-04, BB-07r | 1607 | 4 concepts x 30 pieces = 120 rows | concept A gauss(12.009, 0.007407) (adjudicated Cpk 0.72; pre-adjudication generator used sigma 0.00417 -> stale Cpk ~1.28); B/C/D authored bands; Ra coupled to bore error | `modules/16-concept-selection-pugh-ahp/scripts/gen_trials.py` |
| `modules/25-multi-vari/data/multivari-bore.csv` | Lane 10 / Module 25; replanted post-adjudication 2026-11-04, BB-10r-2 | 42501 | 5 pcs x 3 spindles x 3 time blocks = 45 rows | positional offsets -10/-5/0/+5/+10 um about +9 um base (mu = 12.009 mm, the 7.407 um regime; total s ~ 7.566 um on sample), spindle/time offsets 0, eps N(0, 2.4 um) | `modules/25-multi-vari/scripts/gen_multivari_bore.py` |

Simulation-only seeds (no CSV; keys live inside the module scripts): 1507
(Lane 06 / Module 15 claims-audit Monte Carlo, 20,000 trials, p = 0.06),
1317 (Lane 06 / Module 13 raw-idea funnel counts),
20261105 (Lane 08 / Module 18 exercises re-derivation run of
`modules/18-monte-carlo/scripts/mc_bore_stack.py`; registered teaching seed
20261104 unchanged, 10k-run Cpk 1.598, 0 exceedances; key:
`modules/18-monte-carlo/keys/solution-key.md`).

Re-derivation court: every SS/F/effect in the keys above is recomputed from the
raw CSV by the hand-shown python3 in the module README; the holdout prediction
equation is verified against corner means at +++
(pred 17.89, PI 15.75-20.02, obs 18.86) and ---
(pred -2.99, PI -5.12 to -0.86, obs -2.77).

Registered checksums (sha256; verified by `python3 datasets/manifest_verify.py`
from the curriculum root — zero mismatches = exit 0):

```
3996786eed31e764b4bbfd30d63f26c2a5296dbfd0b95537c3602a3f9108cb9a  data/bore-baseline-100.csv
f524c87b1d052fb8662e72a621afbdbcf8054e5e57bde6b11e556c1ee57b518c  data/xbar-r-subgroups.csv
d703ba61a8a67e8a6278893534c0a39f622b6e34a87a71f4a9dcc8941e2ff245  data/lead-defectives.csv
8888e52fb8a3fc3a4199275bc9cc60c066c50d10f58fea94ef0660db8cc7c210  modules/16-concept-selection-pugh-ahp/data/concept_trials.csv
601e769c07fa6c54726c4182395a245b03cd7b0356a2adf9d6aa447def22f048  modules/25-multi-vari/data/multivari-bore.csv
b1f826f95ccb7888d36508aad735cf8e2a3cb8a40f75ff77d98ec22c44953132  modules/28-2way-anova/data/anova-2way.csv
adf2fbb03c57f2cb207347cdf8fc1cc40f8ed43f6db2f186b3700b8b720f6ccf  modules/30-full-factorial-doe/data/doe-2k-full.csv
a86ea8c30adeda11e218acc71aee6f3067b5ac882d398db7d8913fb81e7dc8fd  modules/13-concept-generation/datasets/concept-portfolio.csv
60fb91e96041cfdb43e0b580e6ab8af10f7eb93834067cd7f9998bb13595565e  modules/14-triz-product/datasets/tool-wear.csv
79d6e3ae388c1acd4647d7e45f3efdd2ac8134b45462b407af7fc62855c115b9  modules/15-triz-transactional/datasets/onboarding-durations.csv
dde34835770cce086c045ea577046164c2058a9125d7b8c830d0133a6fdbba44  datasets/gimbal-bore-stack-parameters.csv
a4e1cc36ca7fea3cae083d0f8e507871163c5d01f060da5bafa598ea6c7e211c  datasets/monte-carlo-bore-stack-summary.csv
96be88ca8b378bd31c2ba7ea24d37385e9b3d76971f4704b0ac5537b0b2313c7  modules/04-voice-of-customer/data/kano-responses.csv
cce551a8d4e8f9a577fe914fb9334c8385442588f1ae44c7716408b515b75e1b  modules/05-qfd/data/qfd-cppc-weights.csv
14943e0c3de68bd2fcd0b148fdeed040546b7740372e1ced3ef4e6dee9db3c13  modules/05-qfd/data/qfd-cppc-matrix.csv
54a7f0ef1fe3e72bbac66e4891fd202004513cc082dbdf544d1cb367ec2fb82f  modules/05-qfd/data/qfd-cppc-roof.csv
0b4a3ea4ad71af3a9abf7d135f3b37f5b78006266307bb5dee775a4ea3b25170  modules/05-qfd/data/qfd-cppc-targets.csv
9c09de704004c6820588306e7bc2f4283be8ddf4fa7dc2a6109ad55e21dc58ca  modules/05-qfd/data/qfd-claims-weights.csv
5b6ecec3772e49995d757829f5554f52253955251764222a538c2c717fa2cb0e  modules/05-qfd/data/qfd-claims-matrix.csv
c33150561bc485f5662c45086c7d4ed006f5ad238b5213a607ff1d01c2609b49  modules/05-qfd/data/qfd-claims-roof.csv
e9d042e4e582193fad4897483f3937f310e37bc5bc26dd9147b1e54dfee99275  data/attribute-inspectors.csv
b032ea6583b8b2617166584ea8ab2a21aeca88c7021b53fe0c6a52f8f4d2ed29  data/cpk072-bore-subgroups.csv
448ce4b8d3a4b6a73a78ce04b0231ce8c20df1e504a947ccb59798b8099faca5  data/flatness-lognormal.csv
e304f8b6c0a3461ed0c706933af1e2743677be454d1a94c7328846437cda4dce  data/gage-rr-bore.csv
601e769c07fa6c54726c4182395a245b03cd7b0356a2adf9d6aa447def22f048  data/multivari-bore.csv
02e88fe173b40502388cac4aa7145835e7c6615ef630370dde8f6a3197896b49  data/regression-multi.csv
be7fa18ccdecd51fcd12d652e1a05a23bc4790d0d790c9b6381217cec6fc1829  data/regression-simple.csv
1728c0ee84b97434de42b25d8051f66a53977ca9ba64a8a99b086ff155fdb3bc  modules/01-intro-dmedi/data/baseline-bore-diameter.csv
6ca9b1de3b8707b53b047ee44a3913b1d464ffdc395527f6bf6ebb0c710a0e2f  modules/02-define-overview/data/bore-inspection-dpmo.csv
1b560fd88291069c7b4eec319e64a42c1bb066828088c6a73fc604b4a8a14ad9  modules/02-define-overview/data/order-lead-time.csv
79d2e1dec73c35cf7a71700196a122fd1f48e5d092d5c7a66161adee42e98d2a  modules/03-charter-mgpp-risk-comms/data/ed-door-to-provider-minutes.csv
ae0bbc0ccfe2d7757f6c6ba97631526c3b0a19a5d447f23c9ea2e70baa1fcd82  modules/03-charter-mgpp-risk-comms/data/insurance-claims-cycle-time.csv
394fd9b0d44f329cc6c6893cc5439e145a87bad4fd8c44654e97b54c8151b008  modules/19-hypothesis-testing/data/bore-30.csv
c96bf6604fea149a5cf7af8618ac57bc62f9bc745ce31069a46b74c89d66151a  modules/20-confidence-intervals/data/ci-trap-overlap.csv
2d0343fae4136572d7619d503a799ad9e2056793e622b40c1027c2c4e37f7adc  modules/21-testing-means-medians-variances/data/coating-ab-bore.csv
23fb870518eca8bf98126dcec8200927ea5ea05f1cbcde87f0af0c3a43053994  modules/21-testing-means-medians-variances/data/coolant-anova.csv
e6448d2c8e12de4b4d33fede60e508318e96bf402e9541b42423f152a44f80d4  modules/21-testing-means-medians-variances/data/paired-feed.csv
8a97bc0cb842b41652b2506bd229f08236b28315516ad752bc7d3694b0ea350a  modules/22-proportion-chi-square/data/bore-100-gof.csv
52e815f9d523693b35d0e720093391a32b1d5aebf864b381b95aec779a4b99c7  modules/22-proportion-chi-square/data/cnc-ab.csv
d48c6aebe84d362c5c33f84bbb041675974fc2f382b88ba2227c16adf06d3aa0  modules/22-proportion-chi-square/data/defect-machine.csv
b2ca7d369605d986bcc8c6323ca00cef1f8702f339dc01a458d82cab3700f169  modules/22-proportion-chi-square/data/scrap-shifts.csv
be7fa18ccdecd51fcd12d652e1a05a23bc4790d0d790c9b6381217cec6fc1829  modules/23-simple-regression/data/regression-simple.csv
02e88fe173b40502388cac4aa7145835e7c6615ef630370dde8f6a3197896b49  modules/24-multiple-regression/data/regression-multi.csv
6ffde1dbd4475b357a4966d9055aacacbea0b00d5a5279e8b1202622e774d2ee  modules/26-design-fmea/data/dfmea-worksheet.csv
2e0fe09509013eeea85ce6a526fa86bd887020a5efed5a2f46221db8c6b6ab30  modules/27-detailed-design/data/design-control-checklist.csv
72e8b2612fe1c91dcefabfdc0773e0a2e39cd479ed45fed46936df5ff11a42bf  modules/27-detailed-design/data/thermal-warmup-study.csv
bb8a317b4c72294f1c1f594215937064fedf9bdab2e08e255d86a093ba115f22  modules/31-fractional-factorial-doe/data/fractional-2k5-2.csv
a63fd2395b14291224d38d683624b99c528aeebe77e944f7dc7ba2f25c4a6517  modules/32-catapult-simulation/data/catapult-results.csv
27e8b8ebffc4c64d9ed9f0bcf1014ea4eef4d753b11205fae08bb8b5ffa9b041  modules/33-key-lean-concepts/data/vsm-baseline.csv
509217b6321f9ce08867496d9158c4249bd7c6284e422d50d0c4cd3fd5b3c7f3  modules/34-lean-design/data/gate-review-waits.csv
1b36fdf07e0806b9631de2f9c30660b007a0e686cda395b8621edba6c06615fb  modules/35-dfma/data/gimbal-teardown.csv
30bcced6e143abb86340a93fe9d7c4f44249613ac85c2dcb03015aff5defd918  modules/36-intro-reliability/data/weibull-failure-times.csv
9e81e142d1ae2157cd8371a7edb534df58bee02108f6ca4ef53ea56e85b77e56  modules/37-doe-curvature/data/bore-curvature.csv
2eb238a284c674c352e9b25d5401d0b3d32832b5316f8ba324fff0f0ce8807b7  modules/38-conjoint/data/conjoint-cards.csv
e91e311853e0b5b2ab97b5a9209613c73f67502c5929fcd4b17f49c2f422dab1  modules/38-conjoint/data/conjoint-ranks.csv
a670ca1c4835944c412aa1ab8cf08ec14478d7bfc6f14a727a37e7ac1f3fecab  modules/39-mixture-designs/data/coolant-mixture.csv
8ac178b137c5641aac13720c7bcaae6a06500f23a8f66ae9e53336e75b30c1ad  modules/40-robust-design/data/robust-bore.csv
d8411e8f75bddff98a45674859cb540f17ac2d76804251fab0d9a4def0355f78  modules/41-helicopter-rsm-lab/data/helicopter-rsm.csv
9464c3ef0026ec61ba19de6648fd6bde910283a468ce9c5e78ff28afc22338f2  modules/42-prototype-pilot/data/pilot-bore-30day.csv
0d53f90461497aacdfdbdb0ea7bf3d0dbe14e2b5bdabcdaa042089d57a75312f  modules/42-prototype-pilot/data/pilot-ra-daily.csv
be57d9b2042d8bd719daea0c56d5cc1e132d5055bd74f14952a43d46cd9788e7  modules/42-prototype-pilot/data/pilot-scrap-daily.csv
```


## Registry seal (GAP-5, 2026-11-04)

GAP-5 sealing lane reconciled the registry against EVERY CSV on disk
(find . -name "*.csv" = 61 files). 20 were already registered and verified
(python3 datasets/manifest_verify.py -> 20 PASS, 0 SKIP, 0 FAIL, exit 0).
The 41 datasets below were ON DISK BUT UNREGISTERED (fail-closed sealing
correction): they are now registered with sha256 checksums (appended to the
checksum block above, covered by manifest_verify.py) and their provenance as
stated on disk. Seven shared datasets were hash-compared for byte-identity:
three pairs are BYTE-IDENTICAL (data/regression-simple.csv ==
modules/23-simple-regression/data/regression-simple.csv; data/regression-multi.csv ==
modules/24-multiple-regression/data/regression-multi.csv;
data/multivari-bore.csv ==
modules/25-multi-vari/data/multivari-bore.csv); every other CSV hash is unique.
Provenance that was flagged unstated at sealing time was an honest observation,
not a placeholder: no seed or generator statement existed on disk for that CSV;
the named owner then supplied the generator/seed or declared the file authored
(all such rows are resolved above as of 2026-11-04, registry-completion pass).

| Dataset | sha256-12 | Rows | Seed / provenance |
|---|---|---|---|
| `data/attribute-inspectors.csv` | `e9d042e4e582` | 301 | 713 (Lane 05 receipt, gage-rr module 11) |
| `data/cpk072-bore-subgroups.csv` | `b032ea6583b8` | 26 | 512 (Lane 05 receipt, module 12) |
| `data/flatness-lognormal.csv` | `448ce4b8d3a4` | 61 | 1203 (Lane 05 receipt, module 12 non-normal court) |
| `data/gage-rr-bore.csv` | `e304f8b6c0a3` | 91 | 411 (Lane 05 receipt, module 11) |
| `data/multivari-bore.csv` | `601e769c07fa` | 46 | 42501 (M25 key); BYTE-IDENTICAL to modules/25-multi-vari/data/multivari-bore.csv (which is registered) |
| `data/regression-multi.csv` | `02e88fe173b4` | 37 | 42401 (M24 key); BYTE-IDENTICAL to modules/24-multiple-regression/data/regression-multi.csv |
| `data/regression-simple.csv` | `be7fa18ccdec` | 31 | 42301 (M23 key); BYTE-IDENTICAL to modules/23-simple-regression/data/regression-simple.csv |
| `modules/01-intro-dmedi/data/baseline-bore-diameter.csv` | `1728c0ee84b9` | 51 | authored deterministic (dated weekly run log with operator rotation, no RNG; a bounded 300k-seed sweep of gauss(12.009, 0.007407) found no byte-exact generator, so no synthetic provenance is claimed); M01 court re-derives all keys from raw CSV (modules/01-intro-dmedi/courts/court.py, exit 0 = 17 checks) |
| `modules/02-define-overview/data/bore-inspection-dpmo.csv` | `6ca9b1de3b87` | 21 | authored deterministic (daily defect count table, no RNG); M02 court re-derives the DPMO ladder from raw CSV (modules/02-define-overview/courts/court.py, exit 0 = 20 checks) |
| `modules/02-define-overview/data/order-lead-time.csv` | `1b560fd88291` | 41 | authored deterministic (dated order ledger, dates -> lead_time_days deterministically, no RNG); M02 court re-derives mean/median/sd/P90 from raw CSV (modules/02-define-overview/courts/court.py, exit 0 = 20 checks) |
| `modules/03-charter-mgpp-risk-comms/data/ed-door-to-provider-minutes.csv` | `79d2e1dec73c` | 81 | authored deterministic (ED wait sample with arrival-hour mix, no RNG); M03 court re-derives median/sd/%over-30 from raw CSV (modules/03-charter-mgpp-risk-comms/courts/court.py, exit 0 = 29 checks) |
| `modules/03-charter-mgpp-risk-comms/data/insurance-claims-cycle-time.csv` | `ae0bbc0ccfe2` | 61 | authored deterministic (claims ledger with 60 planted blank closed_date rows, no RNG); M03 court re-derives cycle-time stats from raw CSV (modules/03-charter-mgpp-risk-comms/courts/court.py, exit 0 = 29 checks) |
| `modules/19-hypothesis-testing/data/bore-30.csv` | `394fd9b0d44f` | 31 | 42190 (M19/20 keys) |
| `modules/20-confidence-intervals/data/ci-trap-overlap.csv` | `c96bf6604fea` | 31 | 42290 (M20 key.md) |
| `modules/21-testing-means-medians-variances/data/coating-ab-bore.csv` | `2d0343fae413` | 61 | 42191 (M21 README) |
| `modules/21-testing-means-medians-variances/data/coolant-anova.csv` | `23fb870518ec` | 31 | 42193 (M21 README) |
| `modules/21-testing-means-medians-variances/data/paired-feed.csv` | `e6448d2c8e12` | 26 | 42192 (M21 README) |
| `modules/22-proportion-chi-square/data/bore-100-gof.csv` | `8a97bc0cb842` | 101 | 42197 (M22 key.md) |
| `modules/22-proportion-chi-square/data/cnc-ab.csv` | `52e815f9d523` | 3 | 42195 (M22 key.md) |
| `modules/22-proportion-chi-square/data/defect-machine.csv` | `d48c6aebe84d` | 5 | 42196 (M22 key.md) |
| `modules/22-proportion-chi-square/data/scrap-shifts.csv` | `b2ca7d369605` | 11 | 42194 (M22 key.md) |
| `modules/23-simple-regression/data/regression-simple.csv` | `be7fa18ccdec` | 31 | 42301 (scripts/gen_regression_simple.py); byte-identical twin registered at data/regression-simple.csv |
| `modules/24-multiple-regression/data/regression-multi.csv` | `02e88fe173b4` | 37 | 42401 (scripts/gen_regression_multi.py); byte-identical twin registered at data/regression-multi.csv |
| `modules/26-design-fmea/data/dfmea-worksheet.csv` | `6ffde1dbd447` | 13 | authored deterministic (scripts/gen_dfmea.py, no RNG) |
| `modules/27-detailed-design/data/design-control-checklist.csv` | `2e0fe0950901` | 19 | authored deterministic (design-control checklist mapping, no RNG); M27 derive_keys.py re-derives tolerance math + DFMEA linkage from raw CSV (exit 0 = 18 checks) |
| `modules/27-detailed-design/data/thermal-warmup-study.csv` | `72e8b2612fe1` | 13 | authored deterministic (warmup/no-model deviation pairs, no RNG); M27 derive_keys.py re-derives the warmup contrast from raw CSV (exit 0 = 18 checks) |
| `modules/31-fractional-factorial-doe/data/fractional-2k5-2.csv` | `bb8a317b4c72` | 17 | 43108 (M31 solution-key) |
| `modules/32-catapult-simulation/data/catapult-results.csv` | `a63fd2395b14` | 21 | 43201 (data/simulator.py) |
| `modules/33-key-lean-concepts/data/vsm-baseline.csv` | `27e8b8ebffc4` | 8 | authored deterministic (VSM process table, no RNG); M33 court re-derives 15/15 checks from raw CSV (modules/33-key-lean-concepts/courts/court.py, exit 0) |
| `modules/34-lean-design/data/gate-review-waits.csv` | `509217b6321f` | 6 | authored deterministic (gate-wait table, no RNG); M34 court re-derives 16/16 checks from raw CSV (modules/34-lean-design/courts/court.py, exit 0) |
| `modules/35-dfma/data/gimbal-teardown.csv` | `1b36fdf07e08` | 15 | authored deterministic (teardown worksheet, no RNG); M35 court re-derives 21/21 checks from raw CSV (modules/35-dfma/courts/court.py, exit 0) |
| `modules/36-intro-reliability/data/weibull-failure-times.csv` | `30bcced6e143` | 41 | 42114 (scripts/generate_dataset.py; byte-identical replay court-checked in M36 court) |
| `modules/37-doe-curvature/data/bore-curvature.csv` | `9e81e142d1ae` | 23 | 37001 (data/compute.py, deterministic regen) |
| `modules/38-conjoint/data/conjoint-cards.csv` | `2eb238a284c6` | 10 | authored deterministic (data/compute.py card design, no RNG) |
| `modules/38-conjoint/data/conjoint-ranks.csv` | `e91e311853e0` | 10 | 38001 (data/compute.py) |
| `modules/39-mixture-designs/data/coolant-mixture.csv` | `a670ca1c4835` | 15 | 39001 (data/compute.py) |
| `modules/40-robust-design/data/robust-bore.csv` | `8ac178b137c5` | 33 | 40001 (data/compute.py) |
| `modules/41-helicopter-rsm-lab/data/helicopter-rsm.csv` | `d8411e8f75bd` | 40 | 41001 (data/compute.py) |
| `modules/42-prototype-pilot/data/pilot-bore-30day.csv` | `9464c3ef0026` | 1201 | 42016 (data/gen_pilot.py) |
| `modules/42-prototype-pilot/data/pilot-ra-daily.csv` | `0d53f9046149` | 31 | 42016 (data/gen_scrap.py + gen_pilot.py) |
| `modules/42-prototype-pilot/data/pilot-scrap-daily.csv` | `be57d9b2042d` | 31 | 42016 (data/gen_scrap.py) |
