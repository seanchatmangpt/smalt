#!/usr/bin/env bash
# settle_cas_court.sh — shim court for R196's settle_token_ok?/2 (mutate lane 253, v26.10.16).
#
# Subject: lib/smalt/messaging/amqp/queue_store.ex — settle_token_ok?/2, the
# token-scoped settlement CAS (audit Finding 2, lane R244). A settle
# (complete/release/deadletter) carrying a stale/zombie disposition token must
# refuse typed :lock_lost and leave the message + new owner's lock untouched.
#
# Protocol (scripts/shim_court/lib.sh):
#   BASELINE  sha256(lib/smalt/messaging/amqp/queue_store.ex)
#   BEFORE    the "token-scoped settlement (R244)" describe in
#             test/amqp/queue_store_test.exs (line 725) is GREEN on the
#             pristine module.
#   SHIM      apply_shim makes settle_token_ok?/2 always return true
#             (marker: `# SHIM-COURT: R196 settle CAS bypassed`) — the CAS
#             compares nothing, any token settles any message.
#   AFTER     the zombie-token tests MUST FAIL — the zombie settle now
#             succeeds instead of refusing :lock_lost. The flip is the
#             non-vacuity proof. Typed: the failure output must name the
#             R244 describe, not be a compile error.
#   RESTORE   sha256 byte-exact, fail-closed.
#
# Exit 0 pass / 1 fail / 3 loud skip.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

source "$(dirname "$0")/lib.sh"

SUBJECT=lib/smalt/messaging/amqp/queue_store.ex
export TESTFILE=test/amqp/queue_store_test.exs
export R244_LINE=742
export MIX_BUILD_ROOT=_build-lane268
export AFTER_LOG=/tmp/r196_settle_cas_after.log

command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"
[ -f "$SUBJECT" ] || shim_court_skip "subject missing: $SUBJECT"
grep -q 'defp settle_token_ok?' "$SUBJECT" \
    || shim_court_skip "subject degraded: queue_store.ex lacks settle_token_ok? (already mutated?)"
grep -q 'token-scoped settlement (R244)' "$TESTFILE" \
    || shim_court_skip "witness missing: R244 describe not in $TESTFILE"

shim_court_self_check

# Bypass the settlement CAS: every clause collapses to true so a zombie token
# settles (completes/releases/deadletters) out from under the new owner.
apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import os
import sys
import time
path = sys.argv[1]
src = open(path).read()
old = """  defp settle_token_ok?(%{lock_token: stored}, expected) when is_binary(expected),
    do: stored == expected

  defp settle_token_ok?(_m, _nil_or_absent), do: true
"""
new = """  defp settle_token_ok?(_m, _expected) do # SHIM-COURT: R196 settle CAS bypassed
    true # SHIM-COURT: R196 settle CAS bypassed — zombie tokens settle freely
  end
"""
count = src.count(old)
assert count == 1, f"expected exactly one settle_token_ok? body, got {count}"
open(path, "w").write(src.replace(old, new))
# Force mix to see the edit: an in-place rewrite inside the same mtime second
# is invisible to the compiler's change detection (witnessed: AFTER ran the
# stale pristine beam and the flip looked vacuous).
import time
os.utime(path, (time.time() + 2, time.time() + 2))
PYEOF
}

# BEFORE: the R244 zombie/CAS describe passes against the pristine module.
before_witness() {
    mix test "$TESTFILE:$R244_LINE"
}

# AFTER: with the CAS bypassed, the R244 describe must FAIL (exit != 0) — the
# zombie settle succeeds instead of refusing :lock_lost. Typed: the log must
# name the R244 describe and report test failures, not a compile error.
after_witness() {
    if mix test "$TESTFILE:$R244_LINE" >"$AFTER_LOG" 2>&1; then
        printf '[SHIM] AFTER: R244 describe unexpectedly PASSED under shim (see %s)\n' "$AFTER_LOG"
        return 1
    fi
    grep -q 'token-scoped settlement (R244)' "$AFTER_LOG" || return 1
    grep -qE '[0-9]+ failures?' "$AFTER_LOG" || return 1
    if grep -qiE 'compile|== Compilation error' "$AFTER_LOG"; then
        printf '[SHIM] AFTER: failure is a compile error, not a test flip (see %s)\n' "$AFTER_LOG"
        return 1
    fi
    printf '[SHIM] AFTER: R244 zombie tests FAILED under shim as required (flip witnessed)\n'
}

with_shim "$SUBJECT" \
    "$(declare -f before_witness); before_witness" \
    "$(declare -f after_witness); after_witness"
