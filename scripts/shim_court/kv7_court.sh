#!/usr/bin/env bash
# kv7_court.sh — kv7 drop-list non-vacuity court (P-h step 4, v26.10.31
# mount step 3). Proves the per-face SecretBundle drop-lists (kv7.Bundles,
# KD-03 law) are LOAD-BEARING: transiently breaking one drop-list must flip
# the pinion gate TestKv7PinionFacesByteLaw to FAIL. Exit 0/1/3; a skip is
# loud.
#
# Subject:  posh/internal/dialect/azure/kv7/kv7.go (FaceList drop-list)
# Shim:     remove "value" from the FaceList drop-list — the list face would
#           echo the value on the wire (the exact KD-03 split-brain defect).
# BEFORE:   the pinion gate PASSES against the unmodified law (old signature).
# AFTER:    the pinion gate FAILS under the shim — the flip IS the
#           non-vacuity proof (a gate that still passes a broken drop-list
#           is vacuous, exit 1 [FAIL:AFTER]).
# RESTORE:  sha256-verified byte-exact, fail-closed.
set -euo pipefail
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || dirname "$(cd "$(dirname "$0")" && pwd)")"
cd "$REPO"

SHIM_NAME="kv7"
SUBJECT="posh/internal/dialect/azure/kv7/kv7.go"
SNAP="$(mktemp -d /tmp/kv7-court.XXXXXX)"
SHIM_TARGET='DropKeys:    []string{"version", "versions", "created_seq", "is_version_row", "value"},'
SHIM_REPL='DropKeys:    []string{"version", "versions", "created_seq", "is_version_row"}, // SHIM-COURT: FaceList value-drop removed (KD-03 mutation — list face must NEVER echo the value)'

log() { echo "[court] $*"; }
skip_loud() { echo "[SKIP] kv7_court: $1" >&2; exit 3; }

# fail-closed trap restore
RESTORED=0
restore() {
  if [ "$RESTORED" -eq 0 ]; then
    RESTORED=1
    if [ -f "$SNAP/kv7.go.baseline" ]; then
      cp "$SNAP/kv7.go.baseline" "$SUBJECT"
      if [ "$(shasum -a 256 "$SUBJECT" | awk '{print $1}')" = "$(cat "$SNAP/kv7.go.sha")" ]; then
        log "restore (trap) verified sha256"
      else
        echo "[court] FAIL: trap restore sha256 mismatch — subject CORRUPTED" >&2
      fi
    fi
  fi
}
trap restore EXIT

pinion() {
  (cd posh && go test ./internal/dialect/azure/ -run TestKv7PinionFacesByteLaw -count=1) >/dev/null 2>&1
}

log "BASELINE: sha256($SUBJECT)"
cp "$SUBJECT" "$SNAP/kv7.go.baseline"
shasum -a 256 "$SUBJECT" | awk '{print $1}' > "$SNAP/kv7.go.sha"

log "BEFORE: pinion gate against the UNMODIFIED law (must PASS)"
if ! pinion; then
  echo "[FAIL:BEFORE] pinion gate failed against the unmodified law — refusing to shim" >&2
  exit 1
fi

log "SHIM: remove the FaceList value drop (SHIM-COURT marker)"
python3 - "$SUBJECT" "$SHIM_TARGET" "$SHIM_REPL" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
if src.count(old) < 1:
    print("[court] FAIL: shim found 0 FaceList drop-list sites — BEFORE leg would be vacuous", file=sys.stderr)
    sys.exit(2)
open(path, "w").write(src.replace(old, new, 1))
PYEOF
if ! grep -q 'SHIM-COURT' "$SUBJECT"; then
  cp "$SNAP/kv7.go.baseline" "$SUBJECT"
  echo "[FAIL:SHIM] shimmed subject carries no SHIM-COURT marker" >&2
  exit 1
fi

log "AFTER: pinion gate under the shim (must FAIL — the flip is the proof)"
if pinion; then
  cp "$SNAP/kv7.go.baseline" "$SUBJECT"
  echo "[FAIL:AFTER] pinion gate still PASSES a broken drop-list — gate VACUOUS" >&2
  exit 1
fi
log "AFTER flip witnessed: pinion gate FAILS the broken drop-list"

log "RESTORE + sha256 verify (fail-closed)"
cp "$SNAP/kv7.baseline" "$SUBJECT" 2>/dev/null || cp "$SNAP/kv7.go.baseline" "$SUBJECT"
if [ "$(shasum -a 256 "$SUBJECT" | awk '{print $1}')" != "$(cat "$SNAP/kv7.go.sha")" ]; then
  echo "[FAIL:RESTORE] sha256 mismatch after restore — subject CORRUPTED" >&2
  exit 1
fi
RESTORED=1
rm -rf "$SNAP"
log "RESTORE verified byte-exact (sha256 match)"
echo "[PASS] kv7_court: non-vacuous (BEFORE old-signature, AFTER new-outcome flip, restore verified)"
