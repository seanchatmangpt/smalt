#!/usr/bin/env bash
# disposition_token_court.sh — shim court for R201's connection.ex settle
# threading (mutate lane 273, v26.10.16).
#
# Subject: lib/smalt/messaging/amqp/connection.ex — settle/1 threads the
# delivery's captured lock token into every disposition call site
# (`lock_token: dlv.lock_token` at QueueStore.complete/release/deadletter),
# which is what makes the store-side settle CAS (R196) actually see the
# disposition token on the wire path. Tested but uncourted until now.
#
# Protocol (scripts/shim_court/lib.sh):
#   BASELINE  sha256(lib/smalt/messaging/amqp/connection.ex)
#   BEFORE    the wire test "stale-token disposition is refused (message
#             untouched, lock-lost rejected echo)"
#             (test/amqp/connection_test.exs:231, :amqp_wire) is GREEN on
#             the pristine module.
#   SHIM      apply_shim drops the `lock_token: dlv.lock_token` kwarg at
#             all three settle call sites (complete/release/deadletter),
#             leaving unscoped forms (marker:
#             `# SHIM-COURT: R201 threading removed`) — the store CAS now
#             compares against no disposition token.
#   AFTER     the stale-token wire test MUST FAIL — a stale disposition is
#             accepted and settles out from under the new owner instead of
#             being refused with com.microsoft:message-lock-lost. The flip
#             is the non-vacuity proof. Typed: the failure output must name
#             the stale-token test and report failures, not be a compile
#             error.
#   RESTORE   sha256 byte-exact, fail-closed.
#
# Exit 0 pass / 1 fail / 3 loud skip.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

source "$(dirname "$0")/lib.sh"

SUBJECT=lib/smalt/messaging/amqp/connection.ex
export TESTFILE=test/amqp/connection_test.exs
export STALE_LINE=231
export MIX_BUILD_ROOT="${MIX_BUILD_ROOT:-_build-lane273}"
export AFTER_LOG=/tmp/r201_disposition_token_after.log

command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"
[ -f "$SUBJECT" ] || shim_court_skip "subject missing: $SUBJECT"
grep -q 'lock_token: dlv.lock_token' "$SUBJECT" \
    || shim_court_skip "subject degraded: connection.ex lacks lock_token: dlv.lock_token settle threading (already mutated?)"
grep -q 'stale-token disposition is refused' "$TESTFILE" \
    || shim_court_skip "witness missing: stale-token test not in $TESTFILE"

shim_court_self_check

# Drop the disposition token at all three settle call sites: complete /
# release / deadletter go back to unscoped forms, so the store-side
# settle CAS has nothing to compare and a stale disposition settles.
apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import os
import sys
import time
path = sys.argv[1]
src = open(path).read()
edits = [
    (
        "case QueueStore.complete(dlv.queue, dlv.seq, lock_token: dlv.lock_token) do",
        "case QueueStore.complete(dlv.queue, dlv.seq) do # SHIM-COURT: R201 threading removed",
    ),
    (
        "case QueueStore.release(dlv.queue, dlv.seq, lock_token: dlv.lock_token) do",
        "case QueueStore.release(dlv.queue, dlv.seq) do # SHIM-COURT: R201 threading removed",
    ),
    (
        'case QueueStore.deadletter(dlv.queue, dlv.seq, "rejected", nil, lock_token: dlv.lock_token) do',
        'case QueueStore.deadletter(dlv.queue, dlv.seq, "rejected", nil) do # SHIM-COURT: R201 threading removed',
    ),
]
for old, new in edits:
    count = src.count(old)
    assert count == 1, f"expected exactly one occurrence of {old!r}, got {count}"
    src = src.replace(old, new)
open(path, "w").write(src)
# Force mix to see the edit: an in-place rewrite inside the same mtime second
# is invisible to the compiler's change detection (settle_cas_court precedent).
os.utime(path, (time.time() + 2, time.time() + 2))
PYEOF
}

# BEFORE: the stale-token wire test passes against the pristine module.
before_witness() {
    mix test --include amqp_wire "$TESTFILE:$STALE_LINE"
}

# AFTER: with the token threading removed, the stale-token test must FAIL
# (exit != 0) — the stale disposition is accepted instead of refused with
# com.microsoft:message-lock-lost. Typed: the log must name the stale-token
# test and report test failures, not a compile error.
after_witness() {
    if mix test --include amqp_wire "$TESTFILE:$STALE_LINE" >"$AFTER_LOG" 2>&1; then
        printf '[SHIM] AFTER: stale-token test unexpectedly PASSED under shim (see %s)\n' "$AFTER_LOG"
        return 1
    fi
    grep -q 'stale-token disposition is refused' "$AFTER_LOG" || return 1
    grep -qE '[0-9]+ failures?' "$AFTER_LOG" || return 1
    if grep -qiE '== Compilation error|== Compilation failed' "$AFTER_LOG"; then
        printf '[SHIM] AFTER: failure is a compile error, not a test flip (see %s)\n' "$AFTER_LOG"
        return 1
    fi
    printf '[SHIM] AFTER: stale-token disposition test FAILED under shim as required (flip witnessed)\n'
}

# Serialize per-subject: sibling lanes run courts from the one canonical
# checkout; interleaved shim/restore cycles on one subject read as an inert
# shim. Lock fd held for the whole with_shim scope.
exec 9>>"/tmp/smalt-shim-court-$(basename "$SUBJECT").lock"
flock 9
with_shim "$SUBJECT" \
    "$(declare -f before_witness); before_witness" \
    "$(declare -f after_witness); after_witness"
