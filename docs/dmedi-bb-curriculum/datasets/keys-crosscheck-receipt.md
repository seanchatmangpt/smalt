# Keys Cross-Check Receipt — Lane 18 (Dataset Registry + Keys Court)

Date: 2026-11-04. Root: `/Users/sac/smalt/docs/dmedi-bb-curriculum/`.
Method: waited for tree stabilization (60 s polls on file-inventory hash; STABLE at
poll 28, 12:02:10, after lanes 01–17 had been appending for ~28 min), then ran the
court pass on the final tree. Every number below is this session's real output.

## 1. Dataset registry (fail-closed sweep)

- CSVs on disk: **61**. Registered in `datasets/MANIFEST.md`: **61**.
  `comm` of disk inventory vs checksum block: zero only-on-disk, zero
  registered-but-missing. `shasum -a 256 -c` over the full checksum block: every
  line OK (mismatch grep empty). `python3 datasets/manifest_verify.py`: **exit 0**,
  all PASS, 0 SKIP, 0 FAIL (run by this court, not just cited).
- Zero placeholders. Provenance honesty: 10 CSVs carry explicit UNSTATED-on-disk
  provenance rows (owner named, court re-derivation cited) — a stated honest
  observation, not a placeholder; owner lanes to supply generator/seed or declare
  authored.
- Shared-dataset byte-identity (consistency pass):
  - `data/bore-baseline-100.csv` exists as ONE canonical copy (`data/`), referenced
    by path from modules 08/09/10/12/26/45; no divergent copies exist on disk.
  - Duplicate basenames across modules: exactly 3 (regression-simple,
    regression-multi, multivari-bore); each `data/` twin is byte-identical to its
    `modules/NN*/data/` twin (sha256 equality verified pairwise this session).
  - Every other CSV hash is unique — no two modules reference the same dataset
    with different values. **Zero mismatches.**
- Note: `datasets/MANIFEST.md` was consolidated to 61/61 coverage by the GAP-5
  sealing lane concurrently with this court; this court independently verified
  coverage (comm + shasum -c + manifest_verify.py) rather than trusting it.

## 2. Keys cross-check (derivation-present law)

All 35 solution-key artifacts (`solution-key.md`, `key.md`,
`keys/solution-keys.md`, `keys/*.py`) show derivation steps (python re-derivation
blocks or step-by-step arithmetic), not bare answers. Spot-checked at depth:
06 (billet-mass arithmetic), 07 (stage-delta arithmetic), 28 (ANOVA closure
SST−(SSA+SSB+SSAB+SSE)=0), 29 (df arithmetic), 36 (B10 interpolation arithmetic),
43 (control-limit table), 44 (week arithmetic with counterfactual).

### Spot re-derivations (5 keys, different modules, python3 this session)

| # | Module / key | Re-derived (this court) | Key's claimed | Verdict |
|---|---|---|---|---|
| 1 | M10 X-bar/R limits (`data/xbar-r-subgroups.csv`) | X̄̄ 12.0116, R̄ 0.0191; UCL/LCL 12.0226/12.0006; R UCL 0.0404; OOC {19, 20}; Phase-I (drop 18–20) X̄̄ 12.0097, UCL 12.0208, OOC {18,19,20} | identical | MATCH |
| 2 | M12 Cpk court (`keys/capability_key.py`, run exit 0) | Cpk 0.72 from `data/cpk072-bore-subgroups.csv` (grand 12.0090, R̄ 0.01525, σw 0.00741); spine pair (12.009, 7.407 um) re-derives (12.025−12.009)/(3×0.007407)=0.72; flatness Box-Cox court passes; **ALL COURTS PASS, exit 0** | identical | MATCH |
| 3 | M19 1-sample t (`modules/19-hypothesis-testing/data/bore-30.csv`) | t = 11.197, p = 4.782e-12, 95% CI (12.0059, 12.0085); power n_raw 17.22 → n=18, power(18)=0.817 | 11.197 / 4.78e-12 / (12.0059, 12.0085) / 0.817 | MATCH |
| 4 | M30 DOE effects (`data/doe-2k-full.csv`) | A +11.809, B +9.069, C −0.279, AB −6.686, AC +1.596, BC −0.404, ABC +1.031; grand 10.79; SSE 13.688, MSE 1.711, σ̂ 1.308 | identical to 0.01 | MATCH 5/5 |
| 5 | M18 MC percentiles (`mc_bore_stack.py`, run exit 0, seed 20261104) | ladder 1k/5k/10k: P50 1.390/1.078/1.058, P99.87 17.141/16.771/16.601, Cpk 1.514/1.581/1.588, 0 exceedances — byte-matches `datasets/monte-carlo-bore-stack-summary.csv` | identical | MATCH |

**5/5 re-derivations reproduce. Zero mismatches. Fail-closed list: EMPTY.**

## 3. Session findings (context, not defects)

- `data/bore-baseline-100.csv` was regenerated mid-session (BB-04r, post spine
  adjudication: sigma 4.17 → 7.407 um at mu 12.009). Keys for modules 08/09 were
  refreshed to match; my early provisional mismatch (s 0.004175 vs key 0.004231)
  was against the in-flight file and is RESOLVED on the final tree — module 10's
  key and module 12's court now agree with the on-disk CSV (court exit 0).
- `RUNNING-CASE.md` carries the adjudication note; root `MANIFEST.md` was
  rewritten as the lane registry; the stale Cpk 1.28 cross-note was removed by
  the owning lane. No stale-sigma artifacts remain on the final tree per the
  registry's staleness sweep.
- Provisional early-read anomalies (IQR/outliers/z on the pre-regeneration CSV)
  all dissolve on the final tree; every court result above is from the final,
  stabilized tree.

## 4. Contract receipt

| Item | Result |
|---|---|
| Datasets registered / on disk | 61 / 61, zero unregistered, zero missing |
| Checksum verification | `shasum -a 256 -c` all OK; `datasets/manifest_verify.py` exit 0 |
| Shared-dataset consistency | 3 byte-identical twin pairs; bore-baseline single canonical copy; 0 value conflicts |
| Keys audited | 35 key artifacts, derivation-present law holds on all |
| Keys re-derived (5 across modules) | 5/5 MATCH (M10, M12, M19, M30, M18) |
| Mismatches (fail-closed list) | NONE |
| Standing | ALIVE — court run on the stabilized final tree, all outputs above are this session's real output |
