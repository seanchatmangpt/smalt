# 07-court-x2 — DoD lane module (owned by its lane; see docs/jira/v26.10.14)

# Release receipt gate: run the full admission court TWICE consecutively and
# require two green runs. This is the final gate of the release — a single
# green court is not a receipt; two consecutive fresh greens are. Shifted
# failures between runs are surfaced as the flake signature. ~8 min.
court-x2:
    @bash scripts/court_x2.sh
