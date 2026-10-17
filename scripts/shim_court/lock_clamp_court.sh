#!/usr/bin/env bash
# lock_clamp_court.sh — shim court for the lock-clamp invariant gate (lane M5, v26.10.16).
#
# Subject: gates/lock_clamp_gate.py — the verdict() clamp-window check
# (lo = max(expected-100, expected//2), hi = expected + TOLERANCE_MS) that
# refuses any observed lock delta outside the clamped envelope. This is the
# only one of the 5 invariant gates with no shim court until now.
#
# Protocol (scripts/shim_court/lib.sh):
#   BASELINE  sha256(gates/lock_clamp_gate.py)
#   BEFORE    the REAL verdict() run in-process on the pristine module REFUSES
#             an unclamped-high delta (3600000ms where 30000ms is clamped)
#             while still ADMITTING the fully-clamped observation.
#   SHIM      apply_shim neuters the clamp-window check (condition -> always
#             true), marked `SHIM-COURT`.
#   AFTER     the SAME unclamped observation must be ADMITTED — the flip is
#             the non-vacuity proof: the window check is load-bearing.
#   RESTORE   sha256 byte-exact, fail-closed.
#
# Exit 0 pass / 1 fail / 3 loud skip.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

source "$(dirname "$0")/lib.sh"

export GATE=gates/lock_clamp_gate.py
export WITNESS=scripts/shim_court/lock_clamp_witness.py

command -v python3 >/dev/null 2>&1 || shim_court_skip "python3 not on PATH"
[ -f "$GATE" ] || shim_court_skip "subject missing: $GATE"
[ -f "$WITNESS" ] || shim_court_skip "witness missing: $WITNESS"
grep -q 'lo, hi = max(expected - 100, expected // 2), expected + TOLERANCE_MS' "$GATE" \
    || shim_court_skip "subject degraded: lock_clamp_gate.py lacks the clamp-window check (already mutated?)"

shim_court_self_check

apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = ("            lo, hi = max(expected - 100, expected // 2), expected + TOLERANCE_MS\n"
       "            check(lo <= delta <= hi,\n")
new = ("            lo, hi = max(expected - 100, expected // 2), expected + TOLERANCE_MS  # SHIM-COURT lock-clamp: window computed but unenforced\n"
       "            check(delta == delta,  # SHIM-COURT lock-clamp: clamp-window check neutered — admits unclamped deltas\n")
assert src.count(old) == 1, f"expected exactly one clamp-window check, got {src.count(old)}"
open(path, "w").write(src.replace(old, new))
PYEOF
}

# BEFORE: pristine verdict refuses the unclamped delta (and still admits clamped).
before_witness() {
    python3 "$WITNESS" refused "$GATE"
}

# AFTER: neutered verdict must ADMIT the same unclamped delta — the flip.
after_witness() {
    python3 "$WITNESS" admitted "$GATE"
}

with_shim "$GATE" \
    "$(declare -f before_witness); before_witness" \
    "$(declare -f after_witness); after_witness"
