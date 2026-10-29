# 45-impl24.just — IMPL-24 reductions ceiling fence (PB-2 denominator -> standing gate).
#
# Gate:  scripts/reductions_gate.py — re-measures per-stage reductions for one
#        4-step settlement orchestration (statistics method, OTP 29 toolchain)
#        and refuses if ANY stage exceeds 2x the PB-2 baseline.
# Court: scripts/shim_court/reductions_gate_court.sh — ceiling shimmed to 0.5x
#        baseline; the gate must FAIL:CEILING; restore sha256 byte-exact.
# Baselines: production = tmp/bench/pb2-reductions-step.jsonl (PB-2's artifact;
#            the gate SKIPs typed, exit 3, until it lands). Court fixture =
#            tmp/bench/impl24-court-baseline.jsonl (court-owned, real-measured).
#        Override either with REDUCTIONS_GATE_BASELINE.

# Fail-closed per-stage reductions ceiling. Exit 0 pass / 1 CEILING BREACH /
# 2 env error / 3 SKIP (PB-2 baseline absent — loud, never a fake pass).
reductions-gate:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    exec python3 scripts/reductions_gate.py

# Non-vacuity: shim the ceiling to 0.5x baseline -> gate must FAIL:CEILING,
# restore byte-exact (shim-court protocol, sha256 fail-closed).
reductions-gate-court:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    exec bash scripts/shim_court/reductions_gate_court.sh
