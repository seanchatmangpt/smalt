#!/usr/bin/env bash
# blob_worm_court.sh — non-vacuity court for gates/blob_worm_gate.py
# (lane M2, v26.10.16). Uses the reusable protocol in lib.sh:
#
#   BASELINE  sha256(gates/blob_worm_gate.py)
#   BEFORE    the healthy gate REFUSES the mutated write against a
#             WORM-locked container observation ("overwrite-accepted":
#             409 -> 200, ContainerLocked stripped). Witness exits 0 when
#             the old signature (refusal) holds.
#   SHIM      neuter the overwrite-refusal check inside verdict() —
#             marked SHIM-COURT, backup taken by lib.sh.
#   AFTER     the shimmed gate now ADMITS the same mutated write. This
#             flip is the non-vacuity proof: the gate's 409/ContainerLocked
#             enforcement demonstrably changes outcomes.
#   RESTORE   byte-exact vs baseline sha256 or [FAIL:RESTORE] (fail-closed).
#
# Azure-semantics pin (checked, not assumed): real Azure PERMITS new-blob
# writes into a hold-locked container; it refuses OVERWRITES of existing
# blobs under legal hold. The gate pins only the overwrite case (and delete),
# which matches real-service semantics — the shim therefore targets the
# overwrite-of-existing-blob refusal, never a new-blob-write path.
#
# Exit: 0 non-vacuous / 1 typed FAIL / 3 loud SKIP.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
source scripts/shim_court/lib.sh

SUBJECT=gates/blob_worm_gate.py
WITNESS=scripts/shim_court/blob_worm_witness.py

[ -f "$REPO/$SUBJECT" ] || shim_court_skip "subject gate missing: $SUBJECT"
[ -f "$REPO/$WITNESS" ] || shim_court_skip "witness missing: $WITNESS"
command -v python3 >/dev/null || shim_court_skip "python3 not on PATH"

apply_shim() {
    # Neuter ONLY the overwrite-under-hold refusal check (delete checks stay
    # intact so the shim is minimal and specifically flips the target leg).
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = """    check(obs.get("overwrite_locked_status") == 409,
          f"overwrite under hold -> 409 (got {obs.get('overwrite_locked_status')})")
    check(obs.get("overwrite_locked_code") == "ContainerLocked",
          "overwrite refusal carries ContainerLocked")"""
new = """    pass  # SHIM-COURT: overwrite-409 refusal check neutered for non-vacuity probe (temporary; restore is sha256-verified)"""
if old not in src:
    print("apply_shim: expected verdict() overwrite-check block not found", file=sys.stderr)
    sys.exit(1)
open(path, "w").write(src.replace(old, new, 1))
PYEOF
}

shim_court_self_check

with_shim "$REPO/$SUBJECT" \
    "python3 $REPO/$WITNESS refuse $REPO/$SUBJECT" \
    "python3 $REPO/$WITNESS admit $REPO/$SUBJECT"
