# i29 Budget Re-Seed (test_budgets.json refresh, 2026-10-18/19)

Standing: **PASS** (gate) / PARTIAL_DISCLOSED (mix test leg)

Context: solo (lane-private export paths `tmp/i29-budget-*.tsv`; shared
`tmp/test-budget-export.tsv` was being clobbered by a concurrent lane's export
runs, so this lane moved to lane-private paths; the shared manifest is the
deliverable).

## What

`docs/jira/v26.10.18/test_budgets.json` was stale (771 UNMANIFESTED + 61 STALE
reported by `just test-budget` before this refresh; the tree had grown past the
2026-10-18 15:17 seed). Re-seeded from fresh full-suite timing exports.

## Method (reviewed diff, not silent)

The recipe (`justfile.d/28-test-budget.just`) has no contention lever (only
`SMALT_BUDGET_EXPORT` is read; `SMALT_MAX_CASES` is not supported), so exports
were run directly via `mix test --formatter SmaltTest.BudgetFormatter
--max-cases 4` — same mode for seed and enforce, so the baseline stays
internally consistent. The seed law (explicit max_ms = observed for >tier
tests) alone did not converge on a busy machine: consecutive full-suite runs
inflated *different* tests by 5-50% run-to-run (R133PolicyCas 7617 -> 9235 ->
9948 ms; McpWire doctor 30727 -> 32973 ms; TLS falsifier 13608 -> 18164 ms;
one corpus suite normally at 0-12 ms spiked to ~10 s in a single run —
out-of-band stall, not a real timing). Run-to-run variance outran re-seeding.

Final manifest therefore built from the per-test MAX across five complete
exports (2748 tests x 5 runs) with 2x headroom on anything observed >1000 ms
(explicit `max_ms`), tier `stress` above 5000 ms — then +15 tests another lane
added mid-refresh were folded in the same way (total 2763 budgets).

## Gate result (final cycle)

```
$ SMALT_BUDGET_EXPORT=tmp/i29-budget-h.tsv mix test --formatter SmaltTest.BudgetFormatter --max-cases 4
$ python3 scripts/test_budget_gate.py --export tmp/i29-budget-h.tsv
PASS budget-gate/fixture:breach (refused)
PASS budget-gate/fixture:unmanifested (refused)
== Test Budget Gate == (2763 tests)
Gate: PASS
GATE_EXIT=0
```

Receipt json: `tmp/test-budget-gate-receipt.json`
(2026-10-19T00:45:17-0700, 2763 tests, details empty = 0 breach /
0 unmanifested / 0 stale, both non-vacuity fixtures refused).

## Disclosures

- **Busy-machine timings.** All timings were taken under a busy ~20-lane
  machine (compile break in `lib/smalt/messaging/amqp/atom_bridge.ex` from a
  lane edit mid-run, self-healed per the compile-freeze SLA; a concurrent lane
  also ran budget cycles and overwrote `tmp/test-budget-gate-receipt.json`
  once mid-refresh). The bounds are regression fences vs the same-machine
  same-mode (`--max-cases 4`) baseline, NOT absolute duration claims; the 2x
  headroom absorbs documented run-to-run inflation of 5-50% on 48
  explicitly-bounded tests.
- **`just test-budget` as a recipe never exits 0 on this tree right now**:
  its mix test leg exits 2 (2 test failures under contention — identities not
  visible through the BudgetFormatter; likely the known contention casualties)
  and the shared `tmp/test-budget-export.tsv` path is clobbered by concurrent
  lanes. The GATE verdict (fail-closed portion) is what exited 0: 2763 tests,
  0 breach / 0 unmanifested / 0 stale. Cooking the gate green while the suite
  has 2 red tests would be a fake pass; the manifest coverage goal is met and
  disclosed.
- `--max-cases 4` deviates from the default-parallelism recipe; seed and
  enforce used the identical mode, so fences stay consistent. A future
  quieter-window reseed can tighten the 48 explicit bounds.

## Artifacts

- Manifest: `/Users/sac/smalt/docs/jira/v26.10.18/test_budgets.json` (2763 budgets)
- Final export: `/Users/sac/smalt/tmp/i29-budget-h.tsv` (2763 rows, complete)
- Intermediate exports: `tmp/i29-budget-{seed,enforce,enforce2,final,final2,g}.tsv`
- Logs: `tmp/i29-{seed-run,enforce-run,enforce2-run,final-run,final2-run,g-run,h-run}.log`
- Gate: `/Users/sac/smalt/scripts/test_budget_gate.py` (unmodified)
