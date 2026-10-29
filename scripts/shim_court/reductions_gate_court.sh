#!/usr/bin/env bash
# reductions_gate_court.sh — non-vacuity court for the IMPL-24 reductions fence.
#
# Subject: scripts/reductions_gate.py (CEILING_FACTOR constant).
# BEFORE: gate passes at ceiling 2.0x baseline (real re-measured settlement
#         orchestration stages are at ~1.0x the seeded baseline).
# SHIM:   ceiling mutated to 0.5x (SHIM-COURT marked) — below the measured
#         stage reductions.
# AFTER:  gate must FAIL with exit 1 (FAIL:CEILING) on the same real
#         re-measurement — the flip IS the non-vacuity proof.
# RESTORE: sha256 byte-exact, fail-closed.
#
# Baseline: the court owns tmp/bench/impl24-court-baseline.jsonl (seeded by
# the gate's real profiler via --seed when absent); PB-2's
# tmp/bench/pb2-reductions-step.jsonl is never written by this court.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO_ROOT
GATE="$REPO_ROOT/scripts/reductions_gate.py"
export REDUCTIONS_GATE_BASELINE="$REPO_ROOT/tmp/bench/impl24-court-baseline.jsonl"

shim_court_self_check

# SKIP loud, never fake.
[ -n "$(command -v python3)" ] || shim_court_skip "python3 not on PATH"
[ -f "$GATE" ] || shim_court_skip "gate script missing: $GATE"
[ -n "$(command -v mix)" ] || shim_court_skip "mix not on PATH"
OTP29="$HOME/.asdf/installs/erlang/29.1.2/bin"
[ -x "$OTP29/erl" ] || shim_court_skip "asdf erlang 29.1.2 absent (repo toolchain pin)"

# Seed the court-owned baseline fixture from a real profiler measurement.
if [ ! -s "$REDUCTIONS_GATE_BASELINE" ]; then
    python3 "$GATE" --seed || shim_court_skip "profiler seed failed"
fi

apply_shim() {
    # SHIM-COURT: drop the ceiling multiplier to 0.5x — under the measured
    # stage reductions, so the same real re-measurement that passed BEFORE
    # must now breach.
    python3 - "$SHIM_FILE" <<'EOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
new = t.replace("CEILING_FACTOR = 2.0",
                "CEILING_FACTOR = 0.5  # SHIM-COURT: forced breach")
assert new != t, "ceiling anchor line not found"
p.write_text(new)
EOF
}

with_shim "$GATE" \
    'python3 "$REPO_ROOT/scripts/reductions_gate.py"' \
    'out="$(python3 "$REPO_ROOT/scripts/reductions_gate.py" 2>&1)"; rc=$?; echo "$out"; [ "$rc" -eq 1 ] && echo "$out" | grep -q "FAIL:CEILING"'
