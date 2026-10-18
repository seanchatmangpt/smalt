# 28-stress — stress tier gate stage (docs/jira/v26.10.18/rewrite-drafts/stress-tier.md)
#
# The :stress tier carries the expensive test bodies (replay-identity fences,
# DETS churn, 10k-op fuzz, 1000-PUT corpus sweep), excluded from plain
# `mix test` by test/test_helper.exs so T1 stays deterministic. Runs
# sequentially in its own gate stage; exit 0 pass / nonzero fail. Population
# fence: test/stress_tier_census_test.exs (runs in T1).

@test-stress:
    mix test --include stress
