# 47-bench-framework — BENCH-14 prospective zero-framework bench gate (gate + non-vacuity)
# BENCH-9 verdict: deletion is a measurement no-op; enforcement is prospective.
# Frozen allowlist per docs/jira/v26.10.21/receipts/bench9-deletion-audit.md.

BF_ROOT := justfile_directory()

# Fail-closed census gate: no new benchee refs, no unannotated :timer.tc in
# scripts/bench beyond the frozen BENCH-9 allowlist. Exit 0 pass / 1 fail.
@bench-framework-gate:
    python3 {{BF_ROOT}}/scripts/bench_framework_gate.py

# Non-vacuity: injected benchee dep + unannotated :timer.tc (temp copy) must
# FAIL, clean real tree must PASS. A gate that cannot refuse is VACUOUS.
@bench-framework-gate-court:
    python3 {{BF_ROOT}}/scripts/bench_framework_gate.py --self-check
