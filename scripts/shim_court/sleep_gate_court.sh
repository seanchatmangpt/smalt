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

# ---------------------------------------------------------------------------
# AZB-22 legs 5-8: verification/ TS + PY scanners (scan_ts_file/scan_py_file).
# Loud SKIP (exit 3) when the verification/ trees are absent — never a fake
# pass. Subjects are scratch files, rm'd after every leg, never committed.
# NOTE: with_shim installs its own EXIT trap and clears it, so this court's
# EXIT cleanup is clobbered after the first with_shim call — every leg does
# explicit rm cleanup instead.
# ---------------------------------------------------------------------------
VERIF_TS="$(cd "$(dirname "$GATE")/.." && pwd)/verification/ts"
VERIF_PY="$(cd "$(dirname "$GATE")/.." && pwd)/verification/py"
[ -d "$VERIF_TS" ] || shim_court_skip "verification/ts absent — TS scanner legs unverifiable"
[ -d "$VERIF_PY" ] || shim_court_skip "verification/py absent — PY scanner legs unverifiable"
export VERIF_TS VERIF_PY

# --- Leg 5: TS classification — annotated `await sleep(50)` passes; an
# unclassified `setTimeout(100)` is REFUSED and NAMED in the verdict.
TS_SUBJECT="$VERIF_TS/.shim_court_subject_ts.ts"
export TS_SUBJECT

printf '// AZB-22 shim-court scratch TS subject (deleted by court)\n' > "$TS_SUBJECT"
printf '// SLEEP-CLASS: TIME-ADVANCE\nawait sleep(50)\n' >> "$TS_SUBJECT"

ts_before() { python3 "$GATE" "$TS_SUBJECT" >/dev/null; }
ts_after() {
    local out
    if out="$(python3 "$GATE" "$TS_SUBJECT" 2>&1)"; then
        echo "[FAIL] gate ACCEPTED unclassified TS setTimeout — VACUOUS GATE" >&2
        return 1
    fi
    echo "$out" | grep -q 'setTimeout(100)' || {
        echo "[FAIL] gate verdict does not name setTimeout(100)" >&2
        return 1
    }
    return 0
}

apply_shim() {
    printf 'setTimeout(100); // SHIM-COURT unclassified TS sleep\n' >> "$SHIM_FILE"
}

with_shim "$TS_SUBJECT" "$(declare -f ts_before); ts_before" "$(declare -f ts_after); ts_after"
rm -f "$TS_SUBJECT"

# --- Leg 6: PY classification — annotated time.sleep(0.05) passes; an
# unclassified asyncio.sleep(0.1) is REFUSED and NAMED.
PY_SUBJECT="$VERIF_PY/.shim_court_subject_py.py"
export PY_SUBJECT

printf '# AZB-22 shim-court scratch PY subject (deleted by court)\n' > "$PY_SUBJECT"
printf '# SLEEP-CLASS: POLL-STEP\ntime.sleep(0.05)\n' >> "$PY_SUBJECT"

py_before() { python3 "$GATE" "$PY_SUBJECT" >/dev/null; }
py_after() {
    local out
    if out="$(python3 "$GATE" "$PY_SUBJECT" 2>&1)"; then
        echo "[FAIL] gate ACCEPTED unclassified PY asyncio.sleep — VACUOUS GATE" >&2
        return 1
    fi
    echo "$out" | grep -q 'asyncio.sleep(0.1)' || {
        echo "[FAIL] gate verdict does not name asyncio.sleep(0.1)" >&2
        return 1
    }
    return 0
}

apply_shim() {
    printf 'asyncio.sleep(0.1)  # SHIM-COURT unclassified py sleep\n' >> "$SHIM_FILE"
}

with_shim "$PY_SUBJECT" "$(declare -f py_before); py_before" "$(declare -f py_after); py_after"
rm -f "$PY_SUBJECT"

# --- Leg 7: poll-step allowlist integrity — a py poll helper named in
# scripts/sleep_gate_classes.json functions passes BECAUSE of the allowlist;
# renaming the function (allowlist escape revoked) REFUSES.
PY_SUBJECT7="$VERIF_PY/.shim_court_subject_py7.py"
export PY_SUBJECT7

printf '# AZB-22 shim-court scratch PY allowlist subject (deleted by court)\n' > "$PY_SUBJECT7"
printf 'def poll_until():\n    time.sleep(0.01)\n' >> "$PY_SUBJECT7"

allow_before() { python3 "$GATE" "$PY_SUBJECT7" >/dev/null; }
allow_after() {
    local out
    if out="$(python3 "$GATE" "$PY_SUBJECT7" 2>&1)"; then
        echo "[FAIL] gate ACCEPTED py sleep after allowlist escape revoked — VACUOUS GATE" >&2
        return 1
    fi
    echo "$out" | grep -q 'time.sleep(0.01)' || {
        echo "[FAIL] gate verdict does not name time.sleep(0.01)" >&2
        return 1
    }
    return 0
}

apply_shim() {
    # Rename the allowlisted function -> sleep loses the allowlist admission.
    # (BSD/macOS sed: in-place needs '' arg; marker on the rewritten line.)
    sed -i '' 's|^def poll_until():|def poll_until_renamed():  # SHIM-COURT allowlist escape revoked|' "$SHIM_FILE"
}

with_shim "$PY_SUBJECT7" "$(declare -f allow_before); allow_before" "$(declare -f allow_after); allow_after"
rm -f "$PY_SUBJECT7"

# --- Leg 8: dual injection across BOTH verification trees -> one gate
# invocation exits 1 NAMING BOTH subjects.
TS_SUBJECT8="$VERIF_TS/.shim_court_subject_ts8.ts"
PY_SUBJECT8="$VERIF_PY/.shim_court_subject_py8.py"
export TS_SUBJECT8 PY_SUBJECT8

printf '// AZB-22 shim-court scratch TS dual subject (deleted by court)\n' > "$TS_SUBJECT8"
printf '// SLEEP-CLASS: TIME-ADVANCE\nawait sleep(50)\n' >> "$TS_SUBJECT8"
printf '# AZB-22 shim-court scratch PY dual subject (deleted by court)\n' > "$PY_SUBJECT8"
printf '# SLEEP-CLASS: POLL-STEP\ntime.sleep(0.05)\n' >> "$PY_SUBJECT8"

dual_before() { python3 "$GATE" "$TS_SUBJECT8" "$PY_SUBJECT8" >/dev/null; }
dual_after() {
    local out
    if out="$(python3 "$GATE" "$TS_SUBJECT8" "$PY_SUBJECT8" 2>&1)"; then
        echo "[FAIL] gate ACCEPTED dual verification-tree injection — VACUOUS GATE" >&2
        return 1
    fi
    echo "$out" | grep -q "shim_court_subject_ts8.ts" || { echo "[FAIL] verdict does not name the TS subject" >&2; return 1; }
    echo "$out" | grep -q "shim_court_subject_py8.py" || { echo "[FAIL] verdict does not name the PY subject" >&2; return 1; }
    echo "$out" | grep -q "setTimeout(100)" || { echo "[FAIL] verdict does not name setTimeout(100)" >&2; return 1; }
    echo "$out" | grep -q "asyncio.sleep(0.1)" || { echo "[FAIL] verdict does not name asyncio.sleep(0.1)" >&2; return 1; }
    return 0
}

apply_shim() {
    printf 'setTimeout(100); // SHIM-COURT unclassified TS sleep\n' >> "$TS_SUBJECT8"
    printf 'asyncio.sleep(0.1)  # SHIM-COURT unclassified py sleep\n' >> "$PY_SUBJECT8"
}

with_shim "$PY_SUBJECT8" "$(declare -f dual_before); dual_before" "$(declare -f dual_after); dual_after"
rm -f "$TS_SUBJECT8" "$PY_SUBJECT8"

# Explicit scratch sweep (EXIT trap is clobbered by with_shim's own traps).
rm -f "$VERIF_TS"/.shim_court_subject* "$VERIF_PY"/.shim_court_subject*

printf '[PASS] sleep_gate court: clean PASSES, injected sleep REFUSED (test + lib + burn + dual-naming + verification TS/PY + py-allowlist + dual-tree), restore byte-exact\n'
