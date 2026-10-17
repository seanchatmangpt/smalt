#!/usr/bin/env bash
# queue_capacity_court.sh — anti-vacuity court for the queue-capacity invariant
# (gates/queue_capacity_gate.py positive case; lib/smalt/messaging/amqp/
# queue_store.ex capacity_full?/1, @capacity 4096).
#
# Protocol (scripts/shim_court/lib.sh): BASELINE sha256 → BEFORE witness (old
# signature: capacity 4096 accepts 3 small enqueues) → SHIM (@capacity 4096 → 1,
# marked SHIM-COURT) → AFTER witness (new outcome: 1st enqueue ok
# boundary-exactly-at-limit, 2nd refused {:error, :capacity}) → RESTORE
# sha256 byte-exact, fail-closed. The AFTER flip is the non-vacuity proof:
# if the capacity gate were dead, the shimmed refusal could not appear.
#
# No git operations. Run via `just shim-court queue-capacity` or directly.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

shim_court_self_check

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUBJECT="$ROOT/lib/smalt/messaging/amqp/queue_store.ex"
[ -f "$SUBJECT" ] || shim_court_skip "subject file missing: $SUBJECT"
command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"

apply_shim() {
    # SHIM-COURT: clamp capacity to the exact boundary 1 — the very next
    # enqueue observes count >= capacity and must refuse.
    python3 - "$SHIM_FILE" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
needle = "@capacity 4096"
if src.count(needle) != 1:
    raise SystemExit(f"expected exactly one '{needle}', found {src.count(needle)}")
open(path, "w").write(src.replace(
    needle,
    "@capacity 1 # SHIM-COURT: capacity clamped to boundary 1 for this court",
    1,
))
PY
}

witness() {
    (cd "$ROOT" && SHIM_CAP_MODE="$1" MIX_BUILD_ROOT="${MIX_BUILD_ROOT:-_build-lane12}" \
        mix run --no-start scripts/shim_court/queue_capacity_witness.exs)
}

before_cmd="cd $(printf %q "$ROOT") && SHIM_CAP_MODE=ok MIX_BUILD_ROOT=${MIX_BUILD_ROOT:-_build-lane12} mix run --no-start scripts/shim_court/queue_capacity_witness.exs"
after_cmd="cd $(printf %q "$ROOT") && SHIM_CAP_MODE=refuse MIX_BUILD_ROOT=${MIX_BUILD_ROOT:-_build-lane12} mix run --no-start scripts/shim_court/queue_capacity_witness.exs"

with_shim "$SUBJECT" "$before_cmd" "$after_cmd"
