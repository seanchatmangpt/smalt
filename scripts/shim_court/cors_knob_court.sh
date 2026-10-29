#!/usr/bin/env bash
# cors_knob_court.sh — non-vacuity court for the CORS headers knobs (lane S2,
# v26.10.20).
#
# Subjects (READ-ONLY — shims land on TEMP COPIES, never lib/):
#   lib/smalt/arm_gateway/router.ex  (knob :smalt, :arm_cors_headers)
#   lib/smalt/egress_router.ex       (knob :smalt, :egress_cors_headers)
#
# What is proven:
#   BEFORE: both routers pass `headers:` through into CORSPlug.init — the
#           structural signature the knobs are load-bearing against.
#   SHIM:   remove the headers pass-through in the TEMP COPIES (SHIM-COURT
#           marker), asserting >=1 site changed per file (a no-op shim would
#           make AFTER vacuous).
#   AFTER:  the structural assertion must FLIP — the pass-through grep finds
#           nothing in the shimmed copies. A court that cannot flip is FAIL.
#   RESTORE: temp copies are discarded; the real lib/ files are never touched
#           and re-verified sha256-stable at the end (fail-closed).
#
# Exit 0 PASS / 1 FAIL / 3 loud SKIP.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
source "$(dirname "$0")/lib.sh"

ARM=lib/smalt/arm_gateway/router.ex
EGRESS=lib/smalt/egress_router.ex

shim_court_self_check || shim_court_fail BASELINE "self-check failed"

[ -f "$ARM" ] || shim_court_skip "subject missing: $ARM"
[ -f "$EGRESS" ] || shim_court_skip "subject missing: $EGRESS"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ARM_COPY="$WORK/arm_router.ex"
EGRESS_COPY="$WORK/egress_router.ex"
cp "$ARM" "$ARM_COPY"
cp "$EGRESS" "$EGRESS_COPY"

# Sha256 the REAL subjects before the court; re-verified at the end.
ARM_SHA="$(shim_court_sha "$ARM")"
EGRESS_SHA="$(shim_court_sha "$EGRESS")"

# The load-bearing structural signature: the knob value reaches CORSPlug.init
# as `headers:` (arm: local var `headers`, egress: same shape in the else arm).
# Witness vars are exported: with_shim runs witnesses under `bash -uc` in a
# child shell, where unexported vars are unbound (loud, by design).
PASS_THROUGH='headers: headers'
export PASS_THROUGH ARM_COPY EGRESS_COPY

# apply_shim edits $SHIM_FILE (the TEMP COPY) in place: strip the headers
# pass-through and stamp the SHIM-COURT marker.
apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
needle = "headers: headers"
n = src.count(needle)
if n < 1:
    sys.exit(2)
open(path, "w").write(
    src.replace(needle, "# SHIM-COURT: headers pass-through removed")
    + "\n# SHIM-COURT: cors-knob pass-through stripped by cors_knob_court\n"
)
PYEOF
}

# Witnesses are per-subject one-liners ($PASS_THROUGH exported for bash -uc):
# BEFORE = the copy carries the pass-through; AFTER = the shimmed copy does not
# (the flip IS the non-vacuity proof).
with_shim "$ARM_COPY" \
    'grep -qF "$PASS_THROUGH" "$ARM_COPY"' \
    '! grep -qF "$PASS_THROUGH" "$ARM_COPY"'
with_shim "$EGRESS_COPY" \
    'grep -qF "$PASS_THROUGH" "$EGRESS_COPY"' \
    '! grep -qF "$PASS_THROUGH" "$EGRESS_COPY"'

# Fail-closed: the real lib/ subjects must be untouched by this court.
[ "$(shim_court_sha "$ARM")" = "$ARM_SHA" ] || \
    shim_court_fail RESTORE "$ARM mutated by court — subject CORRUPTED"
[ "$(shim_court_sha "$EGRESS")" = "$EGRESS_SHA" ] || \
    shim_court_fail RESTORE "$EGRESS mutated by court — subject CORRUPTED"

printf '[court] lib/ subjects sha256-stable across the court run\n'
exit 0
