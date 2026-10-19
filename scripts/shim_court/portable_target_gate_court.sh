#!/usr/bin/env bash
# portable_target_gate_court.sh — non-vacuity court for
# scripts/portable_target_gate.py (verification governance lane, v26.10.19).
#
# Two legs via the shim-court protocol on a scratch subject under
# verification/ (created by this court, deleted on exit):
#   import leg: BEFORE clean subject (Azure SDK + node: + pytest imports,
#     relative-in-tree import) PASSES; SHIM injects an out-of-tree relative
#     import of ../../lib/smalt (SHIM-COURT); AFTER the gate REFUSES.
#   env leg: BEFORE documented env reads pass; SHIM injects an undocumented
#     process.env read (SHIM-COURT); AFTER the gate REFUSES.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$REPO_ROOT/scripts/portable_target_gate.py"
[ -f "$GATE" ] || shim_court_skip "scripts/portable_target_gate.py not found"
SUBJECT_TREE="$REPO_ROOT/verification"
[ -d "$SUBJECT_TREE" ] || shim_court_skip "verification/ tree absent (sibling lane has not landed it)"

SUBJECT="$SUBJECT_TREE/.shim_court_portable_subject.ts"
export SUBJECT GATE

# NOTE: lib.sh's with_shim clears the caller's EXIT trap, so cleanup is
# explicit rm's after each leg, never a trap.

shim_court_self_check

gate_clean() { python3 "$GATE" "$SUBJECT" >/dev/null; }
gate_refuses() {
    if python3 "$GATE" "$SUBJECT" >/dev/null 2>&1; then
        echo "[FAIL] portable-target gate ACCEPTED the shimmed subject — VACUOUS GATE" >&2
        return 1
    fi
    return 0
}

# --- Leg 1: import violation (out-of-tree relative import of lib/smalt) --------
printf '// shim-court scratch subject (deleted by court)\n' > "$SUBJECT"
printf "import { CosmosClient } from '@azure/cosmos';\n" >> "$SUBJECT"
printf "import assert from 'node:assert';\n" >> "$SUBJECT"
apply_shim() {
    printf "import { lib } from '../../lib/smalt/index'; // SHIM-COURT out-of-tree import\n" >> "$SHIM_FILE"
}
with_shim "$SUBJECT" "$(declare -f gate_clean); gate_clean" "$(declare -f gate_refuses); gate_refuses"
rm -f "$SUBJECT"

# --- Leg 2: undocumented env read ------------------------------------------------
printf '// shim-court scratch subject (deleted by court)\n' > "$SUBJECT"
printf 'const base = process.env.SMALT_ARM_BASE;\n' >> "$SUBJECT"
apply_shim() {
    printf 'const secret = process.env.UNDOK_TOKEN; // SHIM-COURT undocumented env read\n' >> "$SHIM_FILE"
}
with_shim "$SUBJECT" "$(declare -f gate_clean); gate_clean" "$(declare -f gate_refuses); gate_refuses"
rm -f "$SUBJECT"

printf '[PASS] portable_target_gate court: import + env legs flip clean-PASS -> shim-REFUSE, restore byte-exact\n'
