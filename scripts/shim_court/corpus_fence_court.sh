#!/usr/bin/env bash
# corpus_fence_court.sh — non-vacuity court for the corpus dead-citation fence.
#
# Law: the dead-citation fence in test/corpus_test.exs must fire on a
# SUBSTRING-PRESERVING mutation of a cited fix site. The fence's token check
# uses call-shape regexes (e.g. \bnormalize_tags\(), so renaming the fix
# (normalize_tags → normalize_tags_vacuity) must flip the fence from PASS to
# FAIL — a fence that survives the mutation is vacuous, and that is a FAIL,
# not a pass.
#
# Protocol (scripts/shim_court/lib.sh):
#   BASELINE → BEFORE (fence passes on unmodified lib) → SHIM (substring-
#   preserving rename, marked SHIM-COURT) → AFTER (fence must FAIL) →
#   RESTORE (sha256 byte-exact, fail-closed).
set -euo pipefail
cd "$(dirname "$0")/../.."
source "scripts/shim_court/lib.sh"

shim_court_self_check

ROOT="$(pwd -P)"
ROUTER="$ROOT/lib/smalt/arm_gateway/router.ex"

apply_shim() {
    # Substring-preserving mutation: rename normalize_tags →
    # normalize_tags_vacuity (definition + call sites). Substring
    # "normalize_tags" survives; the call-shape \bnormalize_tags\( does not.
    python3 - "$SHIM_FILE" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r'\bnormalize_tags\b', 'normalize_tags_vacuity', s)
# SHIM-COURT marker as a full-line comment (a mid-token append breaks the
# defp head and turns the mutation into a compile error, not a fence flip).
s2 = '# SHIM-COURT corpus-fence substring-preserving mutation\n' + s2
open(p, 'w').write(s2)
PY
}

before_witness() {
    MIX_BUILD_ROOT=_build-lane425 mix test test/corpus_test.exs >/dev/null 2>&1
}

after_witness() {
    # The fence must now FAIL loudly: the dead-citation test fires on the
    # vanished call-shape token. Any corpus_test exit != 0 with the dead-
    # citation message present is the flip.
    local out
    out="$(MIX_BUILD_ROOT=_build-lane425 mix test test/corpus_test.exs 2>&1)"
    if echo "$out" | grep -q 'vanished from Smalt.ArmGateway.Router'; then
        return 0
    fi
    echo "AFTER witness: fence did not fire on substring-preserving mutation" >&2
    echo "$out" | tail -20 >&2
    return 1
}

shim_court_skip_usage() { :; }

# SKIP if the toolchain is absent (loud, never a faked pass).
command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"

with_shim "$ROUTER" \
  'MIX_BUILD_ROOT=_build-lane425 mix test test/corpus_test.exs >/dev/null 2>&1' \
  'out="$(MIX_BUILD_ROOT=_build-lane425 mix test test/corpus_test.exs 2>&1)"; echo "$out" | grep -q "vanished from Elixir.Smalt.ArmGateway.Router"'
