# BK-8 / BK-44 — witness-all: fail-closed receipt re-witness gate.
# Walks docs/jira/v26.10.21/receipts/*.md; re-runs safe-class commands for real
# (mix test file-scoped, allowlisted just gates, verification scripts, read-only
# checks, graphlaw cargo tests) with MIX_BUILD_ROOT=_build-witness; everything
# else is a loud [WITNESS-STALE] line. Exit 1 on any red or missing standing.
# Canonical implementation: scripts/witness_all.py

# List dispositions (safe-class command or typed stale reason) without running.
witness-all-dry:
    @python3 scripts/witness_all.py --dry-run

# Full re-witness run (fail-closed; full run is the wrap lane's job).
witness-all:
    @python3 scripts/witness_all.py

# Bounded subset: only receipts whose chosen command is file-scoped mix tests.
witness-all-mix:
    @python3 scripts/witness_all.py --class-filter mix-test
