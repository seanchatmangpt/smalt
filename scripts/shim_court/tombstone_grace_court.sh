#!/usr/bin/env bash
# tombstone_grace_court.sh — shim court proving R197's sweeper tombstone grace
# non-vacuous (v26.10.16).
#
# Subject: lib/smalt/messaging/amqp/sweeper.ex — the R197 tombstone grace:
# run_pass/0 captures expired :message token rows BEFORE the sweeps delete
# them, then re-puts them AFTER QueueStore.sweep re-availed the message rows
# (reinsert_message_tombstones/1), so a client renewing a just-expired token
# gets the pinned 410 :lock_lost instead of 404 :not_found.
#
# Protocol (scripts/shim_court/lib.sh):
#   BASELINE  sha256(lib/smalt/messaging/amqp/sweeper.ex)
#   BEFORE    `mix test test/amqp/sweeper_test.exs` green (5 tests) on the
#             pristine subject — old signature holds (grace present).
#   SHIM      apply_shim neuters the call site of reinsert_message_tombstones/1
#             in run_pass/0 (marker `# SHIM-COURT: R197 tombstone reinsert
#             disabled`), leaving the rest of the module intact.
#   AFTER     `mix test test/amqp/sweeper_test.exs:50` (the 410/lock_lost
#             test) FAILS, and the failure output NAMES that test (not a
#             compile error): without the reinsert the swept token row is
#             gone, so `LockManager.get` returns :error and the 410 assertion
#             never holds. An inert shim leaves the run green -> court FAIL.
#   RESTORE   sha256 byte-exact, fail-closed.
#
# Typed AFTER: the witness greps the log for the test name fragment
# "410 :lock_lost" AND refuses to count a compile error as the flip.
#
# Exit 0 pass / 1 fail / 3 loud skip.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

source "$(dirname "$0")/lib.sh"

SUBJECT=lib/smalt/messaging/amqp/sweeper.ex
WITNESS=test/amqp/sweeper_test.exs
export MIX_BUILD_ROOT=_build-lane261   # lane-local build root, never the shared one

# Loud skip when the environment cannot run the court for real.
command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"
[ -f "$SUBJECT" ] || shim_court_skip "subject missing: $SUBJECT"
[ -f "$WITNESS" ] || shim_court_skip "witness missing: $WITNESS"
grep -q 'reinsert_message_tombstones(doomed)' "$SUBJECT" \
    || shim_court_skip "subject degraded: call site absent from $SUBJECT (grace already neutered?)"
grep -q '410 :lock_lost, not 404' "$WITNESS" \
    || shim_court_skip "witness degraded: 410/lock_lost test absent from $WITNESS"

shim_court_self_check

apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys, time
subject = sys.argv[1]
src = open(subject).read()

# Neuter the tombstone reinsert at its only call site in run_pass/0.
old = "    reinsert_message_tombstones(doomed)\n"
new = (
    "    :ok # SHIM-COURT: R197 tombstone reinsert disabled\n"
    "    # SHIM-COURT: R197 tombstone reinsert disabled (call site neutered)\n"
)
assert src.count(old) == 1, f"call site: expected exactly 1, got {src.count(old)}"
src = src.replace(old, new)

open(subject, "w").write(src)
# Force mix to see the edit: an in-place rewrite inside the same mtime second
# is invisible to the compiler's change detection (witnessed in etag_cas_court).
import os
os.utime(subject, (time.time() + 2, time.time() + 2))
PYEOF
}

# BEFORE: pristine subject — full sweeper suite green (old signature holds:
# grace present; 5 tests, 0 failures).
BEFORE_CMD="cd $(pwd) && MIX_BUILD_ROOT=$MIX_BUILD_ROOT mix test $WITNESS 2>&1 | tail -3"

# AFTER: the renew-after-sweep 410 test by line anchor. Flip proof = the run
# is red AND the failure names the 410/lock_lost test AND it is not a compile
# error.
AFTER_CMD="cd $(pwd) && LOG=\$(mktemp); MIX_BUILD_ROOT=$MIX_BUILD_ROOT mix test $WITNESS:50 >\"\$LOG\" 2>&1; ST=\$?; if grep -q '== Compilation' \"\$LOG\"; then echo '[AFTER] compile error — cannot count as the flip'; tail -15 \"\$LOG\"; exit 1; fi; if [ \$ST -ne 0 ] && grep -q '410 :lock_lost' \"\$LOG\"; then echo '[AFTER] flip proven: shimmed sweeper lost the tombstone grace; the renew-after-sweep 410 test failed as predicted'; grep -E 'test.*410 :lock_lost|assert' \"\$LOG\" | head -4; exit 0; else echo '[AFTER] flip NOT proven (exit '\$ST'):'; tail -12 \"\$LOG\"; exit 1; fi"

# Serialize concurrent court instances: the sweeper subject is shared across
# lanes; overlapping with_shim windows on the same file race
# BEFORE/AFTER/RESTORE against each other (same-file lesson from
# strata_cleanup_court.sh). Same-file lock fd, released at exit.
exec 9>/tmp/tombstone_grace_court.lock
flock 9

with_shim "$SUBJECT" "$BEFORE_CMD" "$AFTER_CMD"
