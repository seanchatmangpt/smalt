# 31-have.just — HAVE supervisory engine (L1) operator recipes.
# Runbook: docs/reference/have-runbook.md. Ledger: tmp/have/ (gitignored).

have-root := justfile_directory()

# Run one pool-saturation cycle (typed alert + dispatch request on deficit).
# Exit 0 always — the alert row IS the signal; the cron loop is the actuator.
@have-cycle:
    python3 {{have-root}}/scripts/have/pool_saturation_guard.py

# Touch the heartbeat and print its age (stale heartbeat = L1 down).
@have-heartbeat:
    python3 {{have-root}}/scripts/have/state_ledger.py heartbeat

# Read the run-state ledger (JSON, one entry per line).
@have-read:
    python3 {{have-root}}/scripts/have/state_ledger.py read

# Append one typed state entry: just have-append <kind> <subject> [detail].
# kind ∈ heartbeat|dispatch|receipt|alert (refuses anything else).
@have-append kind subject detail="":
    python3 {{have-root}}/scripts/have/state_ledger.py append --kind {{kind}} --subject {{subject}} --detail "{{detail}}"

# RP-01 step-3 sanitizer: truncate trailing half-written JSONL lines.
@have-sanitize:
    python3 {{have-root}}/scripts/have/state_ledger.py sanitize

# Anti-vacuity self-check of the saturation guard (fixture-driven courts).
@have-self-check:
    python3 {{have-root}}/scripts/have/pool_saturation_guard.py --self-check
