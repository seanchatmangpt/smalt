#!/usr/bin/env bash
# sleep_gate_court.sh — non-vacuity court for scripts/sleep_gate.py (B8).
#
# Proves the sleep gate is not vacuous via the shim-court protocol, on a
# scratch subject file (no git, byte-exact restore):
#   test-side leg: BEFORE clean (annotated TIME-ADVANCE sleep) PASSES the
#     gate; SHIM injects an unclassified Process.sleep (SHIM-COURT); AFTER
#     the gate REFUSES (exit 1 -> witness flips it to 0).
#   lib-side leg: same with a lib classification (annotated CONTRACT site
#     passes; unclassified injection refused).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

GATE="$(cd "$(dirname "$0")/.." && pwd)/sleep_gate.py"
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sleep_gate_court.XXXXXX")"
SUBJECT="$SCRATCH_DIR/subject.exs"
export GATE SUBJECT

cleanup() { rm -rf "$SCRATCH_DIR"; }
trap cleanup EXIT

shim_court_self_check

# ---------------------------------------------------------------------------
# Leg 1: test-side classification
# ---------------------------------------------------------------------------
printf '# SLEEP-CLASS: TIME-ADVANCE — SHIM-COURT court fixture\n' > "$SUBJECT"
printf 'Process.sleep(50)\n' >> "$SUBJECT"

test_before() { python3 "$GATE" --as=test "$SUBJECT" >/dev/null; }
test_after() {
    if python3 "$GATE" --as=test "$SUBJECT" >/dev/null 2>&1; then
        echo "[FAIL] gate ACCEPTED unclassified test sleep — VACUOUS GATE" >&2
        return 1
    fi
    return 0
}

apply_shim() {
    printf 'Process.sleep(100) # SHIM-COURT unclassified test sleep\n' >> "$SHIM_FILE"
}

with_shim "$SUBJECT" "$(declare -f test_before); test_before" "$(declare -f test_after); test_after"

# ---------------------------------------------------------------------------
# Leg 2: lib-side classification
# ---------------------------------------------------------------------------
printf '# SLEEP-CLASS: CONTRACT — SHIM-COURT court fixture\n' > "$SUBJECT"
printf 'Process.sleep(50)\n' >> "$SUBJECT"

lib_before() { python3 "$GATE" --as=lib "$SUBJECT" >/dev/null; }
lib_after() {
    if python3 "$GATE" --as=lib "$SUBJECT" >/dev/null 2>&1; then
        echo "[FAIL] gate ACCEPTED unclassified lib sleep — VACUOUS GATE" >&2
        return 1
    fi
    return 0
}

apply_shim() {
    printf 'Process.sleep(100) # SHIM-COURT unclassified lib sleep\n' >> "$SHIM_FILE"
}

with_shim "$SUBJECT" "$(declare -f lib_before); lib_before" "$(declare -f lib_after); lib_after"

printf '[PASS] sleep_gate court: clean PASSES, injected sleep REFUSED (both sides), restore byte-exact\n'
