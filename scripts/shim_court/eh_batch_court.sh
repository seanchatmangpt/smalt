#!/usr/bin/env bash
# KD-53 shim court — EH multi-event batch drop (inner messages 2..N).
#
# Subject: lib/smalt/messaging/event_hubs.ex — send_event/3 splits a producer
# createBatch envelope at ingest (KD-COVERS: KD-53); the test witness is
# test/amqp/event_hubs_test.exs, describe "KD-53 multi-event batch split at
# ingest". The SHIM re-introduces the drop by routing send_event to a split-
# disabled stub (the envelope is stored whole as ONE event, delivery unwraps
# only the first inner body — the KD-53 defect shape). The flip (green test
# on the fix, red under the shim) is the non-vacuity proof; RESTORE is
# sha256 byte-exact, fail-closed.
#
# F1 fix (2026-10-16): the old AFTER leg was a bare `! mix test ...:LINE` —
# a compile failure under the shim also exits non-zero and fakes the KD-53
# flip. Now the AFTER witness is typed: the shimmed tree is PRE-COMPILED
# (compile failure -> [FAIL:AFTER], never a flip) and the failing test
# output must name the specific KD-53 witness test. Same shape as
# etag_cas_court.sh's after_witness.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 2
source "scripts/shim_court/lib.sh"

SUBJECT="lib/smalt/messaging/event_hubs.ex"
export TESTFILE="test/amqp/event_hubs_test.exs"
export BUILD_ROOT="${MIX_BUILD_ROOT:-_build-lane13}"
export LINE="$(grep -n '4-event batch envelope is split' "$TESTFILE" | cut -d: -f1)"
[ -n "$LINE" ] || shim_court_skip "KD-53 witness test not found in $TESTFILE"
export TEST_NAME="4-event batch envelope is split"

shim_court_self_check || { echo "[FAIL:SELF-CHECK]" >&2; exit 1; }

apply_shim() {
    python3 - "$SHIM_FILE" <<'PY'
import sys, os, time
path = sys.argv[1]
src = open(path).read()

# SHIM-COURT edit 1: add a split-disabled stub the call site will route to.
needle = "  defp batch_inner_messages(payload) when is_binary(payload) do"
stub = ("  # SHIM-COURT: KD-53 drop re-introduced — split disabled, the batch\n"
        "  # envelope is stored whole as ONE event (defect shape).\n"
        "  defp batch_inner_messages_shim_disabled(_payload), do: nil\n\n")
assert src.count(needle) == 1, "batch_inner_messages defp not found"
src = src.replace(needle, stub + needle)

# SHIM-COURT edit 2: route the send_event call site to the disabled stub.
needle2 = "case batch_inner_messages(body) do"
assert src.count(needle2) == 1, "batch_inner_messages call site not found"
src = src.replace(needle2,
                  "case batch_inner_messages_shim_disabled(body) do # SHIM-COURT")
open(path, "w").write(src)
# SHIM-COURT: force mix to see the edit — an in-place rewrite inside the same
# mtime second is invisible to the compiler's change detection (the AFTER leg
# would then run the stale pristine beam and the flip would be vacuous).
os.utime(path, (time.time() + 2, time.time() + 2))
PY
}

before_witness() {
    MIX_BUILD_ROOT="$BUILD_ROOT" mix test "$TESTFILE:$LINE"
}

# AFTER: shimmed tree must (a) COMPILE — a compile failure is typed FAIL,
# never a flip; and (b) FAIL the KD-53 witness test BY NAME in the failure
# output (grep the test name before accepting the non-zero exit).
after_witness() {
    # Pre-compile the shimmed tree: surfaces any shim-induced compile error
    # as an explicit typed failure instead of a non-zero exit that the old
    # bare `!` would have read as the flip.
    if ! MIX_BUILD_ROOT="$BUILD_ROOT" mix compile; then
        echo "[FAIL:AFTER] shimmed tree does not compile — flip would be fake" >&2
        return 1
    fi
    local out rc
    out="$(MIX_BUILD_ROOT="$BUILD_ROOT" mix test "$TESTFILE:$LINE" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "[FAIL:AFTER] KD-53 witness test PASSED under the shim — flip absent (shim inert)" >&2
        return 1
    fi
    if ! grep -q "$TEST_NAME" <<<"$out"; then
        echo "[FAIL:AFTER] test run failed without naming the KD-53 witness (compile error or unrelated break):" >&2
        tail -20 <<<"$out" >&2
        return 1
    fi
    echo "[AFTER] KD-53 witness '$TEST_NAME' failed under the shim (rc=$rc) — real flip"
}

# Serialize per-subject: sibling lanes run this same court script from the
# one canonical checkout; interleaved shim/restore cycles on one subject
# read as an inert shim. Hold the lock fd for the whole with_shim (and do
# NOT let the beam inherit it: close fd 9 for spawned mixes is handled by
# flock scope exiting with the script).
exec 9>>"/tmp/smalt-shim-court-$(basename "$SUBJECT").lock"
flock 9
with_shim "$SUBJECT" "$(declare -f before_witness); before_witness" \
                    "$(declare -f after_witness); after_witness"
