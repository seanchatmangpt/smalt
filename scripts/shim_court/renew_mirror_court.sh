#!/usr/bin/env bash
# renew_mirror_court.sh — shim court for R194's renew→message-row mirror
# (mutate lane 262, v26.10.16).
#
# Subject: lib/smalt/messaging/amqp/lock_manager.ex — do_message_renew/3's
# mirror_message_renew/1 call. The lane-242 fix: a message-lock renew is
# serialized through QueueStore's claim server and mirrors locked_until into
# the {queue, seq} message row, so do_sweep (which consults the message row)
# can never sweep a successfully renewed lock at its ORIGINAL expiry.
#
# Protocol (scripts/shim_court/lib.sh):
#   BASELINE  sha256(lock_manager.ex) AND sha256(queue_store.ex) — BOTH files.
#   BEFORE    the R194 regression test in test/amqp/queue_store_test.exs
#             ("sweep/0 does NOT reclaim a renewed message lock (renew mirrors
#             into message row)", line 566 — renew at +50ms, sweep past the
#             original +100ms expiry) is GREEN on the pristine module.
#   SHIM      apply_shim comments out ONLY the mirror_message_renew call in
#             do_message_renew (marker: `# SHIM-COURT: R194 mirror disabled`).
#   AFTER     that test MUST FAIL — the message row keeps its original
#             locked_until, so do_sweep re-avails the lock mid-test (message
#             re-availed). Typed: the failure output must name the R194 test
#             description and report test failures, not be a compile error.
#   RESTORE   BOTH files sha256 byte-exact, fail-closed (lock_manager.ex via
#             with_shim's restore; queue_store.ex is never edited — verified
#             unchanged against its baseline after with_shim returns).
#
# Exit 0 pass / 1 fail / 3 loud skip.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

source "$(dirname "$0")/lib.sh"

SUBJECT=lib/smalt/messaging/amqp/lock_manager.ex
CO_SUBJECT=lib/smalt/messaging/amqp/queue_store.ex
export TESTFILE=test/amqp/queue_store_test.exs
export R194_LINE=590
export MIX_BUILD_ROOT=_build-lane262
export AFTER_LOG=/tmp/r194_renew_mirror_after.log

command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"
[ -f "$SUBJECT" ] || shim_court_skip "subject missing: $SUBJECT"
[ -f "$CO_SUBJECT" ] || shim_court_skip "co-subject missing: $CO_SUBJECT"
grep -q 'mirror_message_renew(lock)' "$SUBJECT" \
    || shim_court_skip "subject degraded: lock_manager.ex lacks mirror_message_renew call (already mutated?)"
grep -q 'renew mirrors into message row' "$TESTFILE" \
    || shim_court_skip "witness missing: R194 test not in $TESTFILE"

shim_court_self_check

# flock self-serialization: only one shim court mutates shared lib/ at a time.
exec 9>/tmp/smalt-shim-court.lock
flock 9

# Second baseline: the co-subject queue_store.ex is on the R194 path (it hosts
# the {:message_renew, ...} handle_call that serializes into do_message_renew)
# but is never edited by this shim. Baseline it here and verify byte-exact
# after with_shim returns — a two-file BASELINE with fail-closed coverage.
CO_BASELINE="$(shim_court_sha "$CO_SUBJECT")"
[ -n "$CO_BASELINE" ] || shim_court_fail BASELINE "could not sha256 $CO_SUBJECT"
shim_court_log SHIM "baseline sha256($CO_SUBJECT) = $CO_BASELINE"

# Disable ONLY the mirror: the token row still renews, the message row keeps
# its ORIGINAL locked_until, so do_sweep re-avails the lock past +100ms.
apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = """    with {:ok, lock} <- renew_lock(Smalt.Store.get(:smalt_sb_locks, token), now_ms, opts) do
      mirror_message_renew(lock)
      {:ok, lock}
    end
"""
new = """    with {:ok, lock} <- renew_lock(Smalt.Store.get(:smalt_sb_locks, token), now_ms, opts) do
      # SHIM-COURT: R194 mirror disabled — renew no longer mirrors locked_until
      # into the {queue, seq} message row; do_sweep sees the stale expiry.
      # mirror_message_renew(lock)
      {:ok, lock}
    end
"""
count = src.count(old)
assert count == 1, f"expected exactly one do_message_renew body, got {count}"
open(path, "w").write(src.replace(old, new))
PYEOF
}

# BEFORE: the R194 regression test passes against the pristine module.
before_witness() {
    mix test "$TESTFILE:$R194_LINE"
}

# AFTER: with the mirror disabled, the R194 test must FAIL — the sweep reclaims
# the renewed lock at its original expiry (message re-availed). Typed: the log
# must name the R194 test description and report failures, not a compile error.
after_witness() {
    if mix test "$TESTFILE:$R194_LINE" >"$AFTER_LOG" 2>&1; then
        printf '[SHIM] AFTER: R194 test unexpectedly PASSED under shim (see %s)\n' "$AFTER_LOG"
        return 1
    fi
    grep -q 'renew mirrors into message row' "$AFTER_LOG" || return 1
    grep -qE '[0-9]+ failures?' "$AFTER_LOG" || return 1
    if grep -qiE '== Compilation error|compile error' "$AFTER_LOG"; then
        printf '[SHIM] AFTER: failure is a compile error, not a test flip (see %s)\n' "$AFTER_LOG"
        return 1
    fi
    printf '[SHIM] AFTER: R194 test FAILED under shim as required (message re-availed; flip witnessed, see %s)\n' "$AFTER_LOG"
}

with_shim "$SUBJECT" \
    "$(declare -f before_witness); before_witness" \
    "$(declare -f after_witness); after_witness"

# Co-subject restore proof: queue_store.ex untouched, byte-exact vs baseline.
CO_ACTUAL="$(shim_court_sha "$CO_SUBJECT")"
if [ "$CO_ACTUAL" != "$CO_BASELINE" ]; then
    shim_court_fail RESTORE \
        "co-subject sha256 mismatch: got $CO_ACTUAL, baseline $CO_BASELINE — $CO_SUBJECT CORRUPTED"
fi
shim_court_log SHIM "RESTORE verified byte-exact for co-subject $CO_SUBJECT"
