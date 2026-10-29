# 49-heir-guard — BK-57 heir-table init-guard gate (BK-33 warm-restart class)
# Every {:heir, Process.whereis(:init), []} :ets.new site needs an
# :ets.info/:ets.whereis existence guard before creation, else a warm
# System.restart/0 halts on "table name already exists".

heir-guard-root := justfile_directory()

# Fail-closed tree scan (GUARDED / UNGUARDED / UNPROVABLE — no silent passes).
@heir-guard:
    python3 {{heir-guard-root}}/scripts/heir_guard_check.py

# Non-vacuity: planted unguarded heir module must be REFUSED, else exit 2.
@heir-guard-self-test:
    python3 {{heir-guard-root}}/scripts/heir_guard_check.py --self-test
