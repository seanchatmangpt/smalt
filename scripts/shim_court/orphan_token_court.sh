#!/usr/bin/env bash
# orphan_token_court.sh — shim court for R178j's orphan_token? sweep arm (lane 229, v26.10.16).
#
# Subject: lib/smalt/messaging/amqp/lock_manager.ex — the orphan_token?/2
# clause guarding the :smalt_sb_locks sweep arm in do_sweep_expired/1. An
# expired :session token row is an orphan iff its {queue, session_id} sessions
# row is gone or was overwritten by a re-acquire (different lock_token); the
# token backing the live sessions row must survive the sweep.
#
# Protocol (scripts/shim_court/lib.sh):
#   BASELINE  sha256(lib/smalt/messaging/amqp/lock_manager.ex)
#   BEFORE    mix test test/amqp/lock_manager_test.exs:178 GREEN on the
#             pristine module ("R178j: sweep reclaims expired session token
#             orphaned by re-acquire; live token survives").
#   SHIM      apply_shim neuters orphan_token?/2 to always return false
#             (marker: `# SHIM-COURT: R178j orphan arm neutered`).
#   AFTER     the SAME test must FAIL — the flip is the non-vacuity proof:
#             the orphan arm is load-bearing for the sweep's orphan reclaim.
#   RESTORE   sha256 byte-exact, fail-closed.
#
# Exit 0 pass / 1 fail / 3 loud skip.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

source "$(dirname "$0")/lib.sh"

SUBJECT=lib/smalt/messaging/amqp/lock_manager.ex
export TESTFILE=test/amqp/lock_manager_test.exs
export R178J_LINE=178
export MIX_BUILD_ROOT=_build-lane229

command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"
[ -f "$SUBJECT" ] || shim_court_skip "subject missing: $SUBJECT"
grep -q 'defp orphan_token?' "$SUBJECT" \
    || shim_court_skip "subject degraded: lock_manager.ex lacks orphan_token? (already mutated?)"
grep -q 'R178j' "$TESTFILE" \
    || shim_court_skip "witness missing: R178j regression test not in $TESTFILE"

shim_court_self_check

# Neuter orphan_token?/2: every clause short-circuits to false so the sweep
# arm's filter never reclaims ANY expired token row (orphaned or not).
apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = """  defp orphan_token?(%{kind: :message}, _now), do: true

  defp orphan_token?(%{kind: :session, queue: q, session_id: sid, lock_token: token}, _now) do
    case Smalt.Store.get(:smalt_sb_sessions, {q, sid}) do
      :error -> true
      {:ok, %{lock_token: ^token}} -> false
      {:ok, _} -> true
    end
  end
"""
new = """  defp orphan_token?(_lock, _now) do # SHIM-COURT: R178j orphan arm neutered
    false # SHIM-COURT: R178j orphan arm neutered — sweep never reclaims expired tokens
  end
"""
assert src.count(old) == 1, f"expected exactly one orphan_token? body, got {src.count(old)}"
open(path, "w").write(src.replace(old, new))
PYEOF
}

# BEFORE: the R178j regression test passes against the pristine module.
before_witness() {
    mix test "$TESTFILE:$R178J_LINE"
}

# AFTER: with the orphan arm neutered, the same test must FAIL (exit != 0) —
# the orphaned token would survive the sweep. Flip = non-vacuity proof.
after_witness() {
    if mix test --warnings-as-errors "$TESTFILE:$R178J_LINE" >/tmp/r178j_after.log 2>&1; then
        printf '[SHIM] AFTER: R178j test unexpectedly PASSED under shim (see /tmp/r178j_after.log)\n'
        return 1
    fi
    grep -q "R178j" /tmp/r178j_after.log || return 1
    grep -qE "[0-9]+ failure" /tmp/r178j_after.log || return 1
    printf '[SHIM] AFTER: R178j test FAILED under shim as required (flip witnessed)\n'
}

with_shim "$SUBJECT" \
    "$(declare -f before_witness); before_witness" \
    "$(declare -f after_witness); after_witness"
