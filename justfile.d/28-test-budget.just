# 28-test-budget — per-test timing budget gate (docs/jira/v26.10.18/rewrite-drafts/budget-gate.md)
#
# RETIRED (v26.10.19 staleness-repair lane): the export producer
# (SmaltTest.BudgetFormatter, test/support/budget_formatter.ex) was deleted
# with test/ at 64f6099. Without a formatter there is no timing export, so
# both recipes are LOUD no-ops: exit 1, message naming the deleted subject.
#
# RESEED PLAN (for the test/internal residual-tier owner):
#   1. re-author a fresh timing formatter in test/internal (exports TSV rows
#      `module\ttest\tms` — scripts/test_budget_gate.py is generic over any
#      export and is UNCHANGED);
#   2. `just test-budget-seed` to record the fresh manifest;
#   3. restore the `mix test --formatter <Fresh>` recipe pair + non-vacuity
#      fixtures, and re-add the (c3) stage in scripts/verify_all.sh.
# scripts/test_budget_gate.py stays on disk (generic gate, no formatter
# coupling).

# Record the manifest from a fresh timing export (bootstrap / deliberate
# budget refresh; the refresh itself is a reviewed diff, not silent).
test-budget-seed:
    #!/usr/bin/env bash
    echo "[RETIRED] test-budget-seed: SmaltTest.BudgetFormatter deleted at 64f6099; reseed plan in this module header. Exit 1."
    exit 1

# Enforce: fresh export + fail-closed gate against the seeded manifest.
test-budget:
    #!/usr/bin/env bash
    echo "[RETIRED] test-budget: SmaltTest.BudgetFormatter deleted at 64f6099; reseed plan in this module header. Exit 1."
    exit 1
