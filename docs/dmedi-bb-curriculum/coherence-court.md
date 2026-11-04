# coherence-court (Lane 19) — DMEDI BB Curriculum

**Standing**: PARTIAL_ALIVE — audited what exists on disk as of 2026-11-04;
fail-closed on gaps (rows below). Read-only audit; no files outside this report were
created or modified. Receipt: courts executed in-session are cited with exit codes;
everything else is read-level evidence.

**Method**: read `RUNNING-CASE.md` first (adjudicated spine as of 2026-11-04:
Cpk 0.72 at σ = 7.407 µm, μ = 12.009 mm, spec 11.975/12.025; lead 18.4 d → ≤ 7 d;
cost $41.80 → ≤ $28.50; MTBF 1,200 h / B10 900 h; 26-week program, gates weeks 5/9/15/21/26).
Polled ~35 min for the build lanes; audited the landed state. Note: the dispatch
contract's lane numbers (Lane 01 charter … Lane 16 control limits) do not match the
on-disk module numbering; this court audits by module directory content, with owners
from `MANIFEST.md` where a row exists.

## Audit 1 — Numbers chain (charter → QFD → cost → capability → DOE → control)

| hop | module | numbers on disk | vs spine | verdict |
|---|---|---|---|---|
| charter/intro | 01-intro-dmedi slides §2, §6 | bore 12.000±0.025; Cpk 0.72→1.33; lead 18.4→≤7 d; cost $41.80→$28.50; 26 wk, gates 5/9/15/21/26; adjudicated pair (0.72, 7.407 µm) taught | identical | PASS |
| VOC/QFD | 05-qfd (slides/lab/solution-key/targets CSV) | EC targets: ±0.008 mm at σ 2.0 µm ⇒ Cpk 1.33; lead 18.4→≤7; cost 41.80→≤28.50; "forwards to Lane 03 costing" | identical | PASS |
| cost gap | 06-target-costing (via MANIFEST + 35-dfma) | $13.30 gap (41.80→28.50), teardown lines, driver savings $14.71; 35-dfma $11.30 = 85.0% of gap | identical | PASS |
| capability baseline | 12-process-capability | re-derives Cpk = 0.7200 exactly at μ 12.009, σ_within = 7.407 µm from its own CSV; court exits 0 | identical | PASS (court run: rc=0) |
| DOE responses | 29/30/31 (+28) | deviation-from-12.000 µm + Ra; factors = spindle/feed/coolant(+coating in M31 5-factor); M29 pins factors/responses verbatim from RUNNING-CASE | identical | PASS |
| control limits | 10-variation-control-charts + 43-process-control | M10 X-bar/R limits from data, Xbb 12.0097 ≈ spine μ; M43 post-improvement σ-hat 0.004392, PCR 1.897, limits inside spec | consistent | PASS |
| downstream | 42-prototype-pilot / 45-capstone | DOE predicted 1.50 → pilot Cpk 1.481 (LCB 1.429 ≥ 1.33) → capstone re-derivation; MTBF 1,200 h / B10 900 h consistent in 36/45 | consistent | PASS |

**Audit 1 verdict: PASS** on the landed chain. No hop diverges from the spine.

## Audit 2 — Test-selection coverage (decision tree vs taught tests)

Tree: `modules/19-hypothesis-testing/decision-tree.md` — 13 tests, 13 paths, each with
CPPC anchor + dataset. All tests taught in M19–M22 (1-sample z, 1-sample t, paired t,
Mann-Whitney U, 2-sample t pooled/Welch, Levene, Bartlett, one-way ANOVA, 1-prop z,
2-prop z, χ² GOF, χ² independence) appear on the tree. Cross-checked M20 (CI: no new
test family) and M28.

**Audit 2 verdict: FAIL** — see drift rows D5, D6.

## Audit 3 — Prereq DAG

Checked every stated prereq pointer against on-disk coverage: 09→08; 11→10; 12→10,11;
16→05,12; 28→09,10,27(!); 30→28,29; 31→30-level intuition; 32→31; 41→30,31,23/24,37;
44→42,43; 45→01–44. All pointer targets exist and cover the required method — except
M28's "Module 27 (one-way ANOVA)" pointer (D1) and the M45 "01–44 complete" claim
(D2/D3 gaps).

**Audit 3 verdict: FAIL** — see drift rows D1–D3.

## Audit 4 — Terminology

Per-spine scan: CTQ (57 files), Y/response, factor/x. The spine pins CTQ-1/2/3
(product/transactional/cost). M29 defines response = "the CTQ Y the DOE measures" and
factor/x per spine. Consistent usage across M19/M29/M30/M31/M41. Violations found:
M04's internal Kano numbering reuses the CTQ ids with different meanings (D4).

**Audit 4 verdict: FAIL** — see drift row D4.

## Drift table (closing worklist)

| id | finding | module | owner | severity |
|---|---|---|---|---|
| D1 | Prereq pointer names "Module 27 (one-way ANOVA)" twice (README lines 13-14, 188); on disk 27 = detailed-design and one-way ANOVA is taught in M21 §6. Every downstream reader of the DAG is misled; M30 inherits it transitively. | 28-2way-anova | Lane 12 (M28 owner, per datasets MANIFEST) | High |
| D2 | Module 02-define-overview has data CSVs only — no README/slides/lab/court landed at audit time. | 02-define-overview | Define-lane owner (unregistered in MANIFEST) | High (gap) |
| D3 | Module 03-charter-mgpp-risk-comms has data CSVs only — no README/slides/court landed at audit time; charter lane is the head of the numbers chain. | 03-charter-mgpp-risk-comms | Define-lane owner (unregistered in MANIFEST) | High (gap) |
| D4 | CTQ id collision: M04 numbers its 10 Kano attributes CTQ-1..CTQ-10 with different meanings than the spine CTQ-1/2/3 (M04 CTQ-2 = no-leaking-hydraulic-ports vs spine CTQ-2 = lead time; M04 CTQ-5 = lead time, CTQ-6 = unit cost vs spine CTQ-3 = cost). Two namespaces, same ids. Fix: rename M04's rows to KA-1..KA-10 or carry an explicit mapping line; today the collision is silently load-bearing (weights forward to M05). | 04-voice-of-customer | Lane 02 | High |
| D5 | Decision tree scope: two-way ANOVA (M28) and Tukey post-hoc (M28, teased from M21 §6) have no path on the M19 flagship tree. Tree's completeness claim is scoped "M19–M22" — honest, but the course teaches tests beyond the tree with no route from Q1. | 19-hypothesis-testing | Lane 09 (M19 owner) | Medium |
| D6 | Regression-family tests (t/F on coefficients, M23/24; Breusch-Pagan M24) also outside the tree; acceptable as a separate family only if the tree says so explicitly. | 19-hypothesis-testing | Lane 09 | Medium |
| D7 | `datasets/MANIFEST.md` "recovered rows" still describe the pre-adjudication generators (bore-baseline gauss(12.009, 0.00417), xbar-r plain gauss, no planted shift) — the disk CSVs re-derive at the adjudicated scale (bore-baseline: n=100, mean 12.009815, sd 0.007417) and M10 documents a planted +0.015 mm shift in subgroups 18-20. Provenance law says seed+generator must re-derive the CSV; as written it cannot. | datasets/MANIFEST.md | data-owner lane (Module-04 wave / Lane 04) | High |
| D8 | Root `MANIFEST.md` registry: modules 02, 03, 10, 27, 41, 44 (partially), 09, 13-15, 17, 18, 20-22, 29, 31, 32, 37-40 have no bundle row. Registry is read by the coherence court as the bundle index; unregistered bundles are unauditable. | MANIFEST.md | owning lanes | Medium |
| D8b | M12 lab flags Lane 04's xbar-r CSV as showing subgroups 19-20 above X̄ UCL while M10 documents the same file as a planted 18-20 special-cause window — two modules describe the same dataset differently (deliberate shift vs incidental OOC). One narrative must win. | 12-process-capability/labs/capability-derivation.md vs 10-variation-control-charts/README.md | Lane 05 / Lane 10-vs-04 data owner | Medium |
| D8c | M42 solution-key still cites "pending Lane 19 adjudication" of CLD-01 — adjudication landed 2026-11-04 (RUNNING-CASE.md); stale "pending" status. | 42-prototype-pilot/keys/solution-key.md | Lane 16 | Low |
| D9 | M05 slides-outline honest-flag (line 46) still presents the σ 4.17 vs 0.72 inconsistency as OPEN ("does NOT re-derive") though the spine adjudication resolved it; M04 court re-derives 1.279 "asserts" stale framing. Update to adjudicated status. | 05-qfd/slides-outline.md, 04-voice-of-customer/court.md | Lane 02 | Medium |

## Receipt

- Root: `/Users/sac/smalt/docs/dmedi-course/` — correction: `/Users/sac/smalt/docs/dmedi-bb-curriculum/`
- Poll: 7 × ~100 s polls over ~35 min; course tree grew 18 → 253+ files during audit; audited the landed state, fail-closed on D2/D3.
- Courts executed in-session: `python3 modules/05-qfd/data/court.py` → exit 0 (ALL CHECKS PASS); `python3 modules/12-process-capability/keys/capability_key.py` → exit 0 (ALL COURTS PASS, incl. the spine Cpk 0.72 court).
- Bottom line: Audit 1 verifies the landed numbers chain — the adjudicated spine pair (Cpk 0.72, σ 7.407 µm) re-derives at every hop, courts exit 0. Audits 2–4 FAIL on specific, owner-assignable rows D1–D9.
