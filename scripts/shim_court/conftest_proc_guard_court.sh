#!/usr/bin/env bash
# conftest_proc_guard_court.sh — proves the R187b guard in
# smalt-cli/tests/conftest.py (`proc = None` before try + `if proc is not None`
# after yield) is NON-VACUOUS: removing it makes pyright flag `proc` as
# possibly-unbound in both substrate fixtures (anonymous_substrate and
# enforce_substrate).
#
#   BASELINE  sha256(smalt-cli/tests/conftest.py)
#   BEFORE    pyright --outputjson: zero reportPossiblyUnboundVariable and
#             zero reportUninitializedInstanceVariable diagnostics on the
#             pristine file. (Missing-import noise from the optional azure dep
#             is out of scope for this court; rules-only filtering.)
#   SHIM      delete the four R187b guard lines; leave marker
#             `# SHIM-COURT: R187b guard removed`.
#   AFTER     pyright --outputjson flags `proc` possibly-unbound (new outcome
#             holds). The flip IS the non-vacuity proof.
#   RESTORE   sha256 byte-exact, fail-closed.
#
# Exit 0 PASS / 1 FAIL / 3 SKIP (loud).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

CONFTEST="$(cd "$(dirname "$0")/../.." && pwd)/smalt-cli/tests/conftest.py"
PYRIGHT="$(command -v pyright || true)"
if [ -z "$PYRIGHT" ]; then
    shim_court_skip "pyright not on PATH and not in smalt-cli/.venv; smalt-cli/pyproject.toml configures no linter that catches possibly-unbound variables"
fi

shim_court_self_check || shim_court_fail SELF-CHECK "restore-detection self-check failed"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/conftest_proc_guard.XXXXXX")"
export WORKDIR CONFTEST PYRIGHT
trap 'rm -rf "$WORKDIR"' EXIT

# apply_shim: remove the R187b guard lines, leave the mandatory SHIM-COURT
# marker. Every shim edit carries the literal token.
apply_shim() {
    local f="$SHIM_FILE"
    sed -i '' \
        -e '/proc = None  # SHIM-COURT: bound before try so post-yield use is total/d' \
        -e '/if proc is not None:  # SHIM-COURT: total path — skip branch never yields/d' \
        "$f"
    printf '# SHIM-COURT: R187b guard removed\n' >> "$f"
    grep -q 'SHIM-COURT: R187b guard removed' "$f"
}

with_shim "$CONFTEST" \
    '"$PYRIGHT" --outputjson --level error "$CONFTEST" > "$WORKDIR/before.json" 2>/dev/null || true
     if grep -q "reportPossiblyUnboundVariable\|reportUninitializedInstanceVariable" "$WORKDIR/before.json"; then
         echo "BEFORE: pristine file already flagged" >&2
         exit 1
     fi
     exit 0' \
    '"$PYRIGHT" --outputjson --level error "$CONFTEST" > "$WORKDIR/after.json" 2>/dev/null || true
     grep -q "reportPossiblyUnboundVariable" "$WORKDIR/after.json" && \
     grep -q "is possibly unbound" "$WORKDIR/after.json" && \
     grep -q "proc" "$WORKDIR/after.json"'
