# 28-test-budget — per-test timing budget gate (docs/jira/v26.10.18/rewrite-drafts/budget-gate.md)
#
# Seed once (first run records the manifest), then every run enforces:
# regression above budget, deleted/renamed test (stale entry), new
# unbudgeted test, or corrupted/missing export all exit 1 fail-closed.
# Non-vacuity: two mutated fixtures (10x breach, unmanifested rename) run
# through the same verdict; an ACCEPTED mutation = VACUOUS GATE, exit 1.
#
# Concurrent-lane isolation (i29): the export path defaults to a PID-suffixed
# file so two simultaneous `just test-budget` runs never O_TRUNC each other's
# export; an explicit SMALT_BUDGET_EXPORT override is honored verbatim.
# Each recipe is a single shell — `just` runs recipes with `sh -cu`, so the
# $$ is stable across formatter+gate and every command is `|| rc=$?`-guarded
# (a bare failing line would trip `-e` and skip the gate). The recipe exits
# with the gate's code, falling back to mix's when the gate passes.

# Record the manifest from a fresh timing export (bootstrap / deliberate
# budget refresh; the refresh itself is a reviewed diff, not silent).
test-budget-seed:
    export SMALT_BUDGET_EXPORT="${SMALT_BUDGET_EXPORT:-tmp/test-budget-export.$$.tsv}"; \
      mixrc=0; grc=0; \
      mix test --formatter SmaltTest.BudgetFormatter || mixrc=$?; \
      python3 scripts/test_budget_gate.py --seed --export "$SMALT_BUDGET_EXPORT" || grc=$?; \
      echo "== test-budget-seed: mix=$mixrc seed-gate=$grc"; \
      if [ "$grc" -ne 0 ]; then exit "$grc"; fi; exit "$mixrc"

# Enforce: fresh export + fail-closed gate against the seeded manifest.
test-budget:
    export SMALT_BUDGET_EXPORT="${SMALT_BUDGET_EXPORT:-tmp/test-budget-export.$$.tsv}"; \
      mixrc=0; grc=0; \
      mix test --formatter SmaltTest.BudgetFormatter || mixrc=$?; \
      python3 scripts/test_budget_gate.py --export "$SMALT_BUDGET_EXPORT" || grc=$?; \
      echo "== test-budget: mix=$mixrc gate=$grc"; \
      if [ "$grc" -ne 0 ]; then exit "$grc"; fi; exit "$mixrc"
