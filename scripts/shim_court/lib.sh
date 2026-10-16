#!/usr/bin/env bash
# shim_court/lib.sh — reusable shim-court protocol (lane S-6, v26.10.14).
#
# Generalizes scripts/mutation_court.py's BEFORE/after/restore phases into a
# shell harness. A "shim court" proves a gate or behavior is NON-VACUOUS by
# transiently replacing a subject file's behavior:
#
#   1. SHA-BASELINE   sha256 the subject file.
#   2. BEFORE         run the before-witness against the UNMODIFIED file;
#                     exit 0 = the OLD signature holds.
#   3. SHIM           call the caller-defined `apply_shim` hook (must edit
#                     <file> in place, marking edits with "SHIM-COURT").
#   4. AFTER          run the after-witness against the SHIMMED file;
#                     exit 0 = the NEW outcome holds. This flip IS the
#                     non-vacuity proof.
#   5. RESTORE        restore from backup; sha256 must equal the baseline
#                     byte-exact. The court FAILS CLOSED on any mismatch.
#
# Exit 0 only if every phase passes. Typed FAIL lines per phase:
#   [FAIL:BASELINE] [FAIL:BEFORE] [FAIL:SHIM] [FAIL:AFTER] [FAIL:RESTORE]
#
# Contract for court scripts (see README.md):
#   - `set -euo pipefail`, then `source "$(dirname "$0")/lib.sh"`.
#   - Define `apply_shim` (edits $SHIM_FILE in place) BEFORE calling with_shim.
#   - Pass witness commands as args 2 and 3 (run via bash -c).
#   - A leg needing a missing environment must SKIP LOUDLY with a reason via
#     `shim_court_skip "reason"` — never fake a pass.

# Bail on unbound vars only here (courts set -e themselves); keep restore safe
# under `set -e` via explicit guards in with_shim.

SHIM_COURT_NAME="$(basename "${0:-shim_court}" .sh)"
SHIM_FILE=""            # set by with_shim; visible to apply_shim
SHIM_BACKUP=""          # mktemp backup of the pristine file
SHIM_BASELINE_SHA=""    # sha256 of the pristine file
SHIM_PHASE="INIT"

shim_court_log() { printf '[%s] %s\n' "$1" "$2"; }

shim_court_fail() {
    # shim_court_fail <PHASE> <detail> — typed FAIL line, then exit 1.
    printf '[FAIL:%s] %s\n' "$1" "$2" >&2
    exit 1
}

shim_court_skip() {
    # SKIP-loud-with-reason: a leg needing a missing environment prints this
    # and exits 3 — recorded as SKIP (never PASS) by the aggregate, and never
    # a faked pass.
    printf '[SKIP] %s: %s\n' "$SHIM_COURT_NAME" "$1"
    exit 3
}

shim_court_sha() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

shim_court_self_check() {
    # Real temp-copy exercise (no mocks): prove the sha256 restore rule
    # DETECTS a corrupted restore. Run once per court invocation.
    local tmp dir target backup good corrupt
    dir="$(mktemp -d)" || return 1
    tmp="$dir/subject.txt"
    printf 'subject-body\n' > "$tmp"
    backup="$dir/backup"
    cp "$tmp" "$backup"
    local base; base="$(shim_court_sha "$tmp")"
    printf 'SHIM-COURT body\n' > "$tmp"
    cp "$backup" "$tmp"                      # clean restore
    good="$(shim_court_sha "$tmp")"
    cp "$backup" "$tmp"
    printf 'x' | dd of="$tmp" bs=1 seek=3 conv=notrunc status=none 2>/dev/null
    corrupt="$(shim_court_sha "$tmp")"
    rm -rf "$dir"
    [ "$good" = "$base" ] && [ "$corrupt" != "$base" ] || {
        printf '[FAIL:SELF-CHECK] restore-detection self-check failed\n' >&2
        return 1
    }
    printf '[self-check] sha256 restore-detection verified\n'
    return 0
}

shim_court_trap() {
    # Interrupt safety: if we die mid-shim, still attempt a byte-exact
    # restore before exiting nonzero.
    if [ -n "${SHIM_BACKUP:-}" ] && [ -f "${SHIM_BACKUP:-}" ] && \
       [ -n "${SHIM_FILE:-}" ] && [ -f "${SHIM_FILE:-}" ] && \
       [ "$SHIM_PHASE" = "AFTER" ]; then
        cp "$SHIM_BACKUP" "$SHIM_FILE"
        if [ "$(shim_court_sha "$SHIM_FILE")" != "$SHIM_BASELINE_SHA" ]; then
            printf '[FAIL:RESTORE] interrupt path: restore did not verify\n' >&2
        fi
    fi
}

with_shim() {
    # with_shim <file> <before-cmd> <after-cmd>
    local file="$1" before_cmd="$2" after_cmd="$3"

    # --- Phase 1: BASELINE ----------------------------------------------------
    SHIM_PHASE="BASELINE"
    if [ ! -f "$file" ]; then
        shim_court_fail BASELINE "subject file not found: $file"
    fi
    SHIM_FILE="$file"
    SHIM_BASELINE_SHA="$(shim_court_sha "$file")"
    if [ -z "$SHIM_BASELINE_SHA" ]; then
        shim_court_fail BASELINE "could not sha256 $file"
    fi
    shim_court_log SHIM "baseline sha256($file) = $SHIM_BASELINE_SHA"

    # --- Phase 2: BEFORE (old signature must hold) ----------------------------
    SHIM_PHASE="BEFORE"
    if ! bash -c "$before_cmd"; then
        shim_court_fail BEFORE \
            "before-witness failed against UNMODIFIED $file — old signature absent; refusing to shim"
    fi
    shim_court_log SHIM "BEFORE witness passed (old signature holds)"

    # --- Phase 3: SHIM ----------------------------------------------------------
    SHIM_PHASE="SHIM"
    if ! declare -F apply_shim >/dev/null; then
        shim_court_fail SHIM "apply_shim() not defined by court script"
    fi
    SHIM_BACKUP="$(mktemp "${TMPDIR:-/tmp}/shim_court.orig.XXXXXX")"
    cp "$file" "$SHIM_BACKUP"
    if ! apply_shim; then
        cp "$SHIM_BACKUP" "$file"
        rm -f "$SHIM_BACKUP"; SHIM_BACKUP=""
        shim_court_fail SHIM "apply_shim failed; file restored from backup"
    fi
    if ! grep -q 'SHIM-COURT' "$file"; then
        cp "$SHIM_BACKUP" "$file"
        rm -f "$SHIM_BACKUP"; SHIM_BACKUP=""
        shim_court_fail SHIM \
            "shimmed $file carries no 'SHIM-COURT' marker; refusing to continue"
    fi
    shim_court_log SHIM "shim applied to $file (SHIM-COURT marker present)"

    # --- Phase 4: AFTER (new outcome must hold) --------------------------------
    SHIM_PHASE="AFTER"
    trap shim_court_trap EXIT INT TERM
    if ! bash -c "$after_cmd"; then
        cp "$SHIM_BACKUP" "$file"
        if [ "$(shim_court_sha "$file")" != "$SHIM_BASELINE_SHA" ]; then
            shim_court_fail RESTORE \
                "restore after AFTER-witness failure did NOT verify byte-exact (baseline $SHIM_BASELINE_SHA)"
        fi
        rm -f "$SHIM_BACKUP"; SHIM_BACKUP=""
        trap - EXIT INT TERM
        shim_court_fail AFTER \
            "after-witness failed against SHIMMED $file — new outcome absent (gate vacuous or shim inert); file restored+verified"
    fi
    shim_court_log SHIM "AFTER witness passed (new outcome holds under shim)"

    # --- Phase 5: RESTORE (byte-exact) ------------------------------------------
    SHIM_PHASE="RESTORE"
    cp "$SHIM_BACKUP" "$file"
    local actual; actual="$(shim_court_sha "$file")"
    rm -f "$SHIM_BACKUP"; SHIM_BACKUP=""
    trap - EXIT INT TERM
    if [ "$actual" != "$SHIM_BASELINE_SHA" ]; then
        shim_court_fail RESTORE \
            "sha256 mismatch after restore: got $actual, baseline $SHIM_BASELINE_SHA — $file CORRUPTED"
    fi
    shim_court_log SHIM "RESTORE verified byte-exact (sha256 match)"

    printf '[PASS] %s: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)\n' \
        "$SHIM_COURT_NAME"
    return 0
}
