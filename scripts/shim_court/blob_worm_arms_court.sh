#!/usr/bin/env bash
# blob_worm_arms_court.sh — non-vacuity court for R188's KD-52 WORM arms
# (lane 248, v26.10.16). Uses the reusable protocol in lib.sh.
#
# Subject: lib/smalt/data_plane/blob_storage.ex — the two `check_worm_arm`
# call sites landed by R188 (KD-52):
#   * snapshot_blob  — "create"  arm (legal hold blocks; retention does not)
#   * set_blob_tier  — "overwrite" arm (hold / locked policy / retention)
#
# Protocol:
#   BASELINE  sha256(blob_storage.ex)
#   BEFORE    the 4 KD-52 WORM-arm tests in
#             test/data_plane/blob_hardening_test.exs
#             ("KD-52 WORM arms: snapshot_blob + set_blob_tier") are GREEN
#             against the pristine file.
#   SHIM      neuter ONLY the two check_worm_arm call sites — snapshot and
#             tier-set succeed under hold — marked `SHIM-COURT`.
#   AFTER     those KD-52 tests FAIL (snapshot 201 / tier 200 under hold
#             instead of 409 ContainerLocked). Typed check: the failure
#             output must NAME the KD-52 tests, not a compile error —
#             a compile failure would fake the flip.
#   RESTORE   sha256 byte-exact vs baseline, fail-closed.
#
# Exit 0 pass / 1 typed FAIL / 3 loud SKIP.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

source "$(dirname "$0")/lib.sh"

SUBJECT=lib/smalt/data_plane/blob_storage.ex
TESTFILE=test/data_plane/blob_hardening_test.exs
export MIX_BUILD_ROOT=_build-lane248   # lane-local build root, never the shared one
export OUT; OUT="$(mktemp "${TMPDIR:-/tmp}/blob_worm_arms.XXXXXX")"
trap 'rm -f "$OUT"' EXIT

command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"
[ -f "$SUBJECT" ] || shim_court_skip "subject missing: $SUBJECT"
[ -f "$TESTFILE" ] || shim_court_skip "test file missing: $TESTFILE"
grep -q 'check_worm_arm(container_meta, "overwrite", now)' "$SUBJECT" \
    || shim_court_skip "subject degraded: blob_storage.ex lacks the KD-52 tier-set overwrite arm (already mutated?)"
grep -q 'check_worm_arm(container_meta, "create", now)' "$SUBJECT" \
    || shim_court_skip "subject degraded: blob_storage.ex lacks the KD-52 snapshot create arm (already mutated?)"

export DESCRIBE_LINE; DESCRIBE_LINE="$(grep -n 'describe "KD-52 WORM arms: snapshot_blob + set_blob_tier' "$TESTFILE" | cut -d: -f1)"
[ -n "$DESCRIBE_LINE" ] || shim_court_skip "KD-52 describe block not found in $TESTFILE"

shim_court_self_check

apply_shim() {
    # Neuter ONLY the two KD-52 check_worm_arm call sites (R188 gates); all
    # other WORM checks (delete/overwrite/create on put_blob/delete_blob,
    # container-level set_legal_hold/set_immutability_policy) stay intact.
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys, time, os
path = sys.argv[1]
src = open(path).read()

# 1. set_blob_tier: overwrite arm
old_tier = ("         # SHIM-COURT / KD-COVERS: KD-52 — Set Blob Tier mutates the stored\n"
            "         # blob, so it rides the \"overwrite\"-arm WORM check (legal hold,\n"
            "         # locked policy, or unexpired retention -> 409 ContainerLocked).\n"
            "         :ok <- check_worm_arm(container_meta, \"overwrite\", now),")
new_tier = ("         # SHIM-COURT: R188 worm arms bypassed for non-vacuity probe\n"
            "         # (temporary; restore is sha256-verified byte-exact).\n"
            "         :ok <- (if true, do: :ok), # SHIM-COURT: KD-52 overwrite arm bypassed")
if src.count(old_tier) != 1:
    print(f"apply_shim: expected exactly one tier-set overwrite arm, got {src.count(old_tier)}", file=sys.stderr)
    sys.exit(1)
src = src.replace(old_tier, new_tier, 1)

# 2. snapshot_blob: create arm
old_snap = ("         # SHIM-COURT / KD-COVERS: KD-52 — a snapshot is a new blob seeded\n"
            "         # from an existing one, so it resolves the existence-scoped arm per\n"
            "         # the moduledoc convention: the source blob exists, making this a\n"
            "         # \"create\" (hold-only) arm — legal hold blocks, time retention does\n"
            "         # not (R5: immutability protects existing data, not namespace\n"
            "         # growth).\n"
            "         :ok <- check_worm_arm(container_meta, \"create\", now),")
new_snap = ("         # SHIM-COURT: R188 worm arms bypassed for non-vacuity probe\n"
            "         # (temporary; restore is sha256-verified byte-exact).\n"
            "         :ok <- (if true, do: :ok), # SHIM-COURT: KD-52 create arm bypassed")
if src.count(old_snap) != 1:
    print(f"apply_shim: expected exactly one snapshot create arm, got {src.count(old_snap)}", file=sys.stderr)
    sys.exit(1)
src = src.replace(old_snap, new_snap, 1)

open(path, "w").write(src)
# Force mix to see the edit: an in-place rewrite inside the same mtime second
# is invisible to the compiler's change detection (witnessed in etag_cas_court).
os.utime(path, (time.time() + 2, time.time() + 2))
PYEOF
}

# BEFORE: pristine arms -> all 4 KD-52 tests green.
before_witness() {
    mix test test/data_plane/blob_hardening_test.exs:"$DESCRIBE_LINE" >"$OUT" 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[blob-worm-arms-court] BEFORE: mix test exited $rc (wanted 0); tail:" >&2
        tail -5 "$OUT" >&2
        return 1
    fi
    grep -q '4 tests, 0 failures' "$OUT" || {
        echo "[blob-worm-arms-court] BEFORE: expected the 4 KD-52 tests green, saw:" >&2
        tail -5 "$OUT" >&2
        return 1
    }
    return 0
}

# AFTER: shimmed arms -> KD-52 tests FAIL. Typed check: the output must name
# the KD-52 tests (real assertion failures), NOT a compile error — a compile
# failure would fake the flip.
after_witness() {
    mix test test/data_plane/blob_hardening_test.exs:"$DESCRIBE_LINE" >"$OUT" 2>&1
    local rc=$?
    [ "$rc" -ne 0 ] || {
        echo "[blob-worm-arms-court] AFTER: mix test exited 0 under shim — flip did not happen (gate vacuous)" >&2
        return 1
    }
    grep -q 'Compilation\|CompileError\|syntax error' "$OUT" && {
        echo "[blob-worm-arms-court] AFTER: output is a COMPILE failure, not the typed flip" >&2
        return 1
    }
    # Must name the KD-52 tests as failures.
    grep -q 'KD-52 WORM arms: snapshot_blob + set_blob_tier' "$OUT" || {
        echo "[blob-worm-arms-court] AFTER: failure output does not name the KD-52 tests" >&2
        return 1
    }
    local named=0
    grep -q 'snapshot under active legal hold' "$OUT" && named=$((named+1))
    grep -q 'set_blob_tier under legal hold' "$OUT" && named=$((named+1))
    grep -q 'set_blob_tier under locked policy' "$OUT" && named=$((named+1))
    [ "$named" -ge 2 ] || {
        echo "[blob-worm-arms-court] AFTER: expected >=2 named KD-52 test failures, saw $named; tail:" >&2
        tail -20 "$OUT" >&2
        return 1
    }
    return 0
}

with_shim "$SUBJECT" \
    "$(declare -f before_witness); before_witness" \
    "$(declare -f after_witness); after_witness"
