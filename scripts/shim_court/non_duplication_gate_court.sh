#!/usr/bin/env bash
# non_duplication_gate_court.sh — non-vacuity court for
# scripts/non_duplication_gate.py (verification governance lane, v26.10.19).
#
# One leg per rule, each via the shim-court protocol on a scratch subject
# under test/internal/ (created by this court, deleted on exit):
#   R1: BEFORE clean subject PASSES; SHIM injects `use Plug.Test`
#       (SHIM-COURT); AFTER the gate REFUSES (exit 1 flipped to 0).
#   R2: same with `assert status == 200`.
#   R3: same with `assert json == %{...}`.
# The AFTER flip IS the non-vacuity proof; restore is sha256 byte-exact.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$REPO_ROOT/scripts/non_duplication_gate.py"
CLASSES="$REPO_ROOT/scripts/non_duplication_classes.json"
[ -f "$GATE" ] || shim_court_skip "scripts/non_duplication_gate.py not found"
[ -f "$CLASSES" ] || shim_court_skip "scripts/non_duplication_classes.json not found"
SUBJECT_TREE="$REPO_ROOT/test/internal"
[ -d "$SUBJECT_TREE" ] || shim_court_skip "test/internal/ residual tier absent (sibling lane has not landed it)"

SUBJECT="$SUBJECT_TREE/.shim_court_non_dup_subject.exs"
export SUBJECT GATE CLASSES

# NOTE: lib.sh's with_shim clears the caller's EXIT trap, so cleanup is
# explicit rm's after each leg, never a trap.

shim_court_self_check

gate_clean() { python3 "$GATE" --classes "$CLASSES" "$SUBJECT" >/dev/null; }
gate_refuses() {
    if python3 "$GATE" --classes "$CLASSES" "$SUBJECT" >/dev/null 2>&1; then
        echo "[FAIL] non-duplication gate ACCEPTED the shimmed subject — VACUOUS GATE" >&2
        return 1
    fi
    return 0
}

# --- Leg 1: R1 transport (absolute violation) ---------------------------------
printf '# shim-court scratch subject (deleted by court)\n' > "$SUBJECT"
printf 'assert subject_ok == :fine\n' >> "$SUBJECT"
apply_shim() {
    printf 'use Plug.Test # SHIM-COURT R1 transport violation\n' >> "$SHIM_FILE"
}
with_shim "$SUBJECT" "$(declare -f gate_clean); gate_clean" "$(declare -f gate_refuses); gate_refuses"
rm -f "$SUBJECT"

# --- Leg 2: R2 Azure status literal --------------------------------------------
printf '# shim-court scratch subject (deleted by court)\n' > "$SUBJECT"
printf 'assert subject_ok == :fine\n' >> "$SUBJECT"
apply_shim() {
    printf 'assert status == 200 # SHIM-COURT R2 status literal\n' >> "$SHIM_FILE"
}
with_shim "$SUBJECT" "$(declare -f gate_clean); gate_clean" "$(declare -f gate_refuses); gate_refuses"
rm -f "$SUBJECT"

# --- Leg 3: R3 JSON-shape assert -------------------------------------------------
printf '# shim-court scratch subject (deleted by court)\n' > "$SUBJECT"
printf 'assert subject_ok == :fine\n' >> "$SUBJECT"
apply_shim() {
    printf 'assert json == %%{"ok" => true} # SHIM-COURT R3 JSON-shape assert\n' >> "$SHIM_FILE"
}
with_shim "$SUBJECT" "$(declare -f gate_clean); gate_clean" "$(declare -f gate_refuses); gate_refuses"
rm -f "$SUBJECT"

printf '[PASS] non_duplication_gate court: R1/R2/R3 each flip clean-PASS -> shim-REFUSE, restore byte-exact\n'
