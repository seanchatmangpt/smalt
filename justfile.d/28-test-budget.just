# 28-test-budget — per-test timing budget gate (docs/jira/v26.10.18/rewrite-drafts/budget-gate.md)
#
# Seed once (first run records the manifest), then every run enforces:
# regression above budget, deleted/renamed test (stale entry), new
# unbudgeted test, or corrupted/missing export all exit 1 fail-closed.
# Non-vacuity: two mutated fixtures (10x breach, unmanifested rename) run
# through the same verdict; an ACCEPTED mutation = VACUOUS GATE, exit 1.

# Record the manifest from a fresh timing export (bootstrap / deliberate
# budget refresh; the refresh itself is a reviewed diff, not silent).
test-budget-seed:
    SMALT_BUDGET_EXPORT=tmp/test-budget-export.tsv \
      mix test --formatter SmaltTest.BudgetFormatter
    python3 scripts/test_budget_gate.py --seed

# Enforce: fresh export + fail-closed gate against the seeded manifest.
test-budget:
    SMALT_BUDGET_EXPORT=tmp/test-budget-export.tsv \
      mix test --formatter SmaltTest.BudgetFormatter
    python3 scripts/test_budget_gate.py
