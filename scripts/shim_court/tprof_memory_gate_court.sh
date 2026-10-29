#!/usr/bin/env bash
# tprof_memory_gate_court.sh — non-vacuity court for the AR-OBS-03 memory fence.
#
# Subject: scripts/tprof_memory_gate.py (CEILING_WORDS constant).
# BEFORE: gate passes at ceiling 200 (real profiled put_doc <= ceiling).
# SHIM:   ceiling mutated to 100 (SHIM-COURT marked) — below the ~134-word
#         measured baseline.
# AFTER:  gate must FAIL with exit 1 (CEILING BREACH) on the same real
#         transaction — the flip IS the non-vacuity proof.
# RESTORE: sha256 byte-exact, fail-closed.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO_ROOT
GATE="$REPO_ROOT/scripts/tprof_memory_gate.py"
export MIX_BUILD_ROOT=_build-obsfence

shim_court_self_check

# SKIP loud, never fake: no mix toolchain or no tools-*/ebin (tprof absent).
[ -n "$(command -v mix)" ] || shim_court_skip "mix not on PATH"
[ -f "$GATE" ] || shim_court_skip "gate script missing: $GATE"
OTP_ROOT="$(mix run --no-start -e 'IO.puts(:code.root_dir())' 2>/dev/null | tail -1)" \
    || shim_court_skip "could not query :code.root_dir/0 via mix"
ls "${OTP_ROOT}"/lib/tools-*/ebin >/dev/null 2>&1 || shim_court_skip "tprof absent (no tools-*/ebin under ${OTP_ROOT})"

run_gate() { "$REPO_ROOT/scripts/tprof_memory_gate.py"; }

apply_shim() {
    # SHIM-COURT: drop ceiling to 100 — under the ~134-word baseline, so the
    # same real transaction that passed BEFORE must now breach.
    python3 - "$SHIM_FILE" <<'EOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
new = t.replace("CEILING_WORDS = 200", "CEILING_WORDS = 100  # SHIM-COURT: forced breach")
assert new != t, "ceiling anchor line not found"
p.write_text(new)
EOF
}

with_shim "$GATE" \
    '"$REPO_ROOT/scripts/tprof_memory_gate.py"' \
    'out="$("$REPO_ROOT/scripts/tprof_memory_gate.py" 2>&1)"; rc=$?; echo "$out"; [ "$rc" -eq 1 ] && echo "$out" | grep -q "FAIL:CEILING"'
