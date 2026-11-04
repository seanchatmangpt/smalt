# Lane 08 Receipt — Modules 17 (Statistical Tolerance) + 18 (Monte Carlo)

Standing: **ALIVE** — all keys executed this session, exit 0, real output captured.

## Subject

`/Users/sac/smalt/docs/dmedi-bb-curriculum/` — Lane 08 owned surfaces only:
`modules/17-statistical-tolerance/`, `modules/18-monte-carlo/`, MANIFEST rows,
and the two Lane 08 datasets in `datasets/`.

## Delivered (all files on disk, verified)

- `modules/17-statistical-tolerance/README.md` — lesson: ONE shared CPPC gimbal
  bore stack (bore Ø ±10 µm / spindle thermal +2±8 µm / fixture ±6 µm /
  tool deflection −1±5 µm), worst-case vs RSS vs Monte Carlo on the same
  stack, side-by-side verdict table, allocation exercise
  (proportional k=0.8276 + cost-weighted equal-marginal-cost λ=0.2727)
- `modules/18-monte-carlo/README.md` — spec (10k runs, seed 20261104,
  σ=tol/3), python3 + spreadsheet + Minitab implementation instructions,
  1k/5k/10k convergence ladder, P0.13/P50/P99.87 vs ±25 µm spec, rule-of-three
  honesty lesson (0 exceedances ≠ p=0, bound 3e-04 vs analytic 8.93e-07),
  tornado (corr + variance share, ranked), verdict vs Cpk 1.33
- `modules/18-monte-carlo/scripts/mc_bore_stack.py` — canonical generator,
  python3 stdlib, seed stated in-file
- `datasets/gimbal-bore-stack-parameters.csv`,
  `datasets/monte-carlo-bore-stack-summary.csv` — MANIFEST-registered
- `datasets/MANIFEST.md` — merged my 2 rows into the concurrent lane's
  rewritten table (rows 14-15), other lanes' rows untouched

## Verification ladder (actual exits)

```
python3 modules/18-monte-carlo/scripts/mc_bore_stack.py  -> EXIT 0 (full report)
# independent court (stdlib-only re-derivation, not importing the module):
P0.13=-13.974 P50=1.058 P99.87=16.601
mu=1.029 sigma=5.033 cpk=1.588 exceed=0
tornado: bore 0.6704/44.78% > thermal 0.5340/28.85% >
         fixture 0.3865/15.73% > deflect 0.3308/11.30%
RSS=5.000  WC band [-28,+30]  allocation WC=24.000 both methods,
cost-weighted rss=4.11
```

Every percentile, tornado row, Cpk, and allocation number in both READMEs
re-derives from the exit-checked script; the independent court reproduced
each to the printed digit. Verdict cross-check: WC FAIL / RSS PASS 1.60 /
MC PASS 1.588 — consistent (WC fails by conservative construction; RSS and
MC agree because the simulated model IS the additive independent-normal
model RSS assumes). Markdown courts: char-length ≤100 on both READMEs
(LINES-OK), H1 matches filename kebab-case.

## Notes

- First cost-weighted attempt (exponent form t·k^(1/c)) was budget-INFEASIBLE
  (WC 25.8 > 24.0) — replaced with the Lagrange equal-marginal-cost form,
  which is budget-exact (WC = 24.000). The failed form is documented in this
  receipt only.
- Concurrent lane rewrote `datasets/MANIFEST.md` mid-flight; I merged my rows
  into their table format rather than overwriting.
- Coordinator owns git (tree is fully untracked — `?? docs/dmedi-bb-curriculum/`);
  no commits made, per contract.
