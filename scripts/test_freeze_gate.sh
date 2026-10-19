#!/usr/bin/env bash
# test_freeze_gate.sh — protected-test freeze gate (Anthropic deterministic-freeze adaptation)
#
# Contract (v26.10.19 reset surfaces): while SMALT_FIX_MODE=1 (set by
# `just fix-start`), the working diff (staged + unstaged, vs HEAD) may NOT
# touch the fresh witness surfaces: test/internal/ and verification/. The
# legacy blanket test/ scope ended when test/ was deleted at 64f6099.
# The failing test is committed frozen (0444) first — the "commit the failing
# test first" ritual — so a fix cannot silently mutate the witness.
# Exit 0 when FIX_MODE is unset or no witness-surface file is in the diff.
# Fail-closed: any git error or unparseable state is a violation, never a pass.
#
# Modes:
#   (default)                      enforce the freeze; exit 0/1
#   --json                         machine-readable {"fix_mode_active":bool,"violations":N,...}
#
# See docs/how-to/how-to-debug-agent.md for the operator ritual.

set -euo pipefail

MARKER=".smalt/fix-mode"
TESTS_LEDGER=".smalt/fix-mode-tests"
fix_mode_active() {
  [ "${SMALT_FIX_MODE:-}" = "1" ] || [ -f "$MARKER" ]
}

violations() {
  # Echo test/ paths in the working diff (staged + unstaged), one per line.
  local names
  names=$(git diff --name-only HEAD -- . 2>/dev/null) || {
    echo "__GATE_GIT_ERROR__" >&2
    return 2
  }
  # Untracked-but-new files under test/ count too: a "new failing test" that
  # is still untracked is exactly what the ritual freezes first.
  local untracked
  untracked=$(git ls-files --others --exclude-standard -- test/ verification/ 2>/dev/null) || true
  printf '%s\n%s\n' "$names" "$untracked" | grep -E '^(test/|verification/)' || true
}

viol_count=0
if fix_mode_active; then
  vout=$(violations) || rc=$?
  if [ "${rc:-0}" -ne 0 ]; then
    echo "TEST_FREEZE_VIOLATION: git diff failed; refusing to pass (fail-closed)" >&2
    exit 1
  fi
  viol_count=$(printf '%s' "$vout" | grep -c . || true)
fi

if [ "${1:-}" = "--json" ]; then
  printf '{"fix_mode_active": %s, "violations": %d, "marker": "%s"}\n' \
    "$(fix_mode_active && echo true || echo false)" "$viol_count" "$MARKER"
  exit 0
fi

if [ "$viol_count" -eq 0 ]; then
  echo "[TEST-FREEZE] OK (fix_mode=$([ "${SMALT_FIX_MODE:-}" = 1 ] || [ -f "$MARKER" ] && echo on || echo off), violations=0)"
  exit 0
fi

{
  echo "TEST_FREEZE_VIOLATION: SMALT_FIX_MODE=1 but the working diff touches test/."
  echo "  Frozen-test law: the failing test is the witness — commit it, do not edit it."
  echo "  Offending files:"
  printf '%s\n' "$vout" | grep . | sed 's/^/    - /'
  echo "  Allowed paths under fix mode: lib/ scripts/ priv/ config/"
  echo "  Fix: revert the test/ edits, or run \`just fix-end\` when the fix cycle is done."
} >&2
exit 1
