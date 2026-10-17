#!/usr/bin/env bash
# dets_growth_court.sh — shim court for the DetsMirror bounded-growth bound
# (mutate lane 323, v26.10.16).
#
# Subject: lib/smalt/store/dets_mirror.ex — sync_all/1's stale-key deletion.
# The bounded-growth fence makes the mirror a PROJECTION of the live ETS
# table: keys deleted from ETS are deleted from the mirror on the next sync,
# so mirror size tracks live size and restore never resurrects deleted rows.
#
# Protocol (scripts/shim_court/lib.sh):
#   BASELINE  sha256(dets_mirror.ex).
#   BEFORE    test/store_dets_growth_test.exs (8 tests) is GREEN on the
#             pristine module.
#   SHIM      apply_shim removes ONLY the stale-key deletion in sync_all
#             (live_keys/stale/Enum.each block), keeping the bare upsert —
#             marker: `# SHIM-COURT: dets bound disabled`.
#   AFTER     the growth census MUST FAIL — the mirror keeps deleted rows
#             (200 vs 100 leak witnessed). Typed: the failure log must name
#             the growth census test and report failures, not a compile error.
#   RESTORE   sha256 byte-exact, fail-closed.
#
# Exit 0 pass / 1 fail / 3 loud skip.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

source "$(dirname "$0")/lib.sh"

SUBJECT=lib/smalt/store/dets_mirror.ex
export TESTFILE=test/store_dets_growth_test.exs
export MIX_BUILD_ROOT=_build-lane323
export AFTER_LOG=/tmp/dets_growth_after.log

command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"
[ -f "$SUBJECT" ] || shim_court_skip "subject missing: $SUBJECT"
[ -f "$TESTFILE" ] || shim_court_skip "witness missing: $TESTFILE"
grep -q 'Enum.each(stale, &:dets.delete(dets_file, &1))' "$SUBJECT" \
    || shim_court_skip "subject degraded: dets_mirror.ex lacks the stale-key deletion (already mutated?)"

shim_court_self_check

# flock self-serialization: only one shim court mutates shared lib/ at a time.
exec 9>/tmp/smalt-shim-court.lock
flock 9

# SHIM: drop the stale-key deletion; keep only the :dets.insert upsert.
# The mirror becomes an upsert-union — deleted ETS keys leak forever.
apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = """          live_keys = MapSet.new(rows, fn {key, _val} -> key end)

          stale =
            dets_file
            |> :dets.match_object(:_)
            |> Enum.map(fn {key, _val} -> key end)
            |> Enum.reject(&MapSet.member?(live_keys, &1))

          Enum.each(stale, &:dets.delete(dets_file, &1))
          :dets.insert(dets_file, rows)
"""
new = """          # SHIM-COURT: dets bound disabled — stale-key deletion removed;
          # the mirror is now an upsert-union and deleted keys leak forever.
          :dets.insert(dets_file, rows)
"""
count = src.count(old)
assert count == 1, f"expected exactly one sync_all stale-deletion block, got {count}"
open(path, "w").write(src.replace(old, new))
PYEOF
}

# BEFORE: the bounded-growth census passes against the pristine module.
before_witness() {
    mix test "$TESTFILE"
}

# AFTER: with the fence disabled, the census must FAIL — deleted keys stay in
# the mirror (200 rows vs the live 100). Typed: the log must name the growth
# census test and report failures, not a compile error.
after_witness() {
    if mix test "$TESTFILE" >"$AFTER_LOG" 2>&1; then
        printf '[SHIM] AFTER: growth census unexpectedly PASSED under shim (see %s)\n' "$AFTER_LOG"
        return 1
    fi
    grep -q 'deleted keys leave the mirror' "$AFTER_LOG" || return 1
    grep -qE '[0-9]+ failures?' "$AFTER_LOG" || return 1
    if grep -qiE '== Compilation error|compile error' "$AFTER_LOG"; then
        printf '[SHIM] AFTER: failure is a compile error, not a test flip (see %s)\n' "$AFTER_LOG"
        return 1
    fi
    printf '[SHIM] AFTER: growth census FAILED under shim as required (200-vs-100 leak witnessed; flip confirmed, see %s)\n' "$AFTER_LOG"
}

with_shim "$SUBJECT" \
    "$(declare -f before_witness); before_witness" \
    "$(declare -f after_witness); after_witness"
