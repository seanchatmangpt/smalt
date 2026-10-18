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

# ---------------------------------------------------------------------------
# Leg 3: burn-script classification (AZB-21): docker/burn/*.sh `sleep [0-9]`
# ---------------------------------------------------------------------------
BURN_DIR="$(cd "$(dirname "$GATE")/.." && pwd)/docker/burn"
BURN_SUBJECT="$BURN_DIR/.shim_court_subject.sh"
export BURN_SUBJECT GATE

printf '#!/usr/bin/env bash\n# AZB-21 shim-court scratch burn subject (deleted by court)\necho ok\n' > "$BURN_SUBJECT"

burn_before() { python3 "$GATE" "$BURN_SUBJECT" >/dev/null; }
burn_after() {
    if python3 "$GATE" "$BURN_SUBJECT" >/dev/null 2>&1; then
        echo "[FAIL] gate ACCEPTED burn-script sleep 1 — VACUOUS GATE" >&2
        return 1
    fi
    python3 "$GATE" "$BURN_SUBJECT" 2>&1 | grep -q "sleep 1" || {
        echo "[FAIL] gate verdict does not name the injected \`sleep 1\`" >&2
        return 1
    }
    return 0
}

apply_shim() {
    printf 'sleep 1 # SHIM-COURT injected burn-script sleep\n' >> "$SHIM_FILE"
}

with_shim "$BURN_SUBJECT" "$(declare -f burn_before); burn_before" "$(declare -f burn_after); burn_after"
rm -f "$BURN_SUBJECT"

# ---------------------------------------------------------------------------
# Leg 4 (AZB-21 anti-vacuity, exact ticket form): seed Process.sleep(10) in a
# test AND `sleep 1` in a burn script -> gate exit 1 NAMING BOTH.
# ---------------------------------------------------------------------------
BURN_SUBJECT2="$BURN_DIR/.shim_court_subject2.sh"
REPO_ROOT="$(cd "$(dirname "$GATE")/.." && pwd)"
TEST_SUBJECT2="$REPO_ROOT/test/.shim_court_subject2.exs"
export BURN_SUBJECT2 TEST_SUBJECT2

printf '# AZB-21 shim-court scratch test subject (deleted by court)\n' > "$TEST_SUBJECT2"
printf '#!/usr/bin/env bash\n# AZB-21 shim-court scratch burn subject (deleted by court)\necho ok\n' > "$BURN_SUBJECT2"

both_before() { python3 "$GATE" "$TEST_SUBJECT2" "$BURN_SUBJECT2" >/dev/null; }
both_after() {
    local out
    if out="$(python3 "$GATE" "$TEST_SUBJECT2" "$BURN_SUBJECT2" 2>&1)"; then
        echo "[FAIL] gate ACCEPTED dual injection — VACUOUS GATE" >&2
        return 1
    fi
    echo "$out" | grep -q "subject2.exs" || { echo "[FAIL] verdict does not name the test subject" >&2; return 1; }
    echo "$out" | grep -q "shim_court_subject2.sh" || { echo "[FAIL] verdict does not name the burn subject" >&2; return 1; }
    echo "$out" | grep -q "Process.sleep(10)" || { echo "[FAIL] verdict does not name Process.sleep(10)" >&2; return 1; }
    echo "$out" | grep -q "sleep 1" || { echo "[FAIL] verdict does not name sleep 1" >&2; return 1; }
    return 0
}

apply_shim() {
    printf 'Process.sleep(10) # SHIM-COURT unclassified test sleep\n' >> "$TEST_SUBJECT2"
    printf 'sleep 1 # SHIM-COURT injected burn-script sleep\n' >> "$SHIM_FILE"
}

with_shim "$BURN_SUBJECT2" "$(declare -f both_before); both_before" "$(declare -f both_after); both_after"
rm -f "$BURN_SUBJECT2" "$TEST_SUBJECT2"

printf '[PASS] sleep_gate court: clean PASSES, injected sleep REFUSED (test + lib + burn + dual-naming), restore byte-exact\n'
