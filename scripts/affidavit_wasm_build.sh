#!/usr/bin/env bash
# affidavit_wasm_build.sh — build the affidavit-wasm cdylib and seed priv/wasm/.
#
# Canonical placement (W17/D1 consolidation): priv/wasm/ is the ONLY artifact
# location — priv/wasm/affidavit_wasm.wasm with its sidecar
# priv/wasm/affidavit.sha256. Consumers (Smalt.Affidavit.WasmEngine, doctor)
# resolve that path; the script is idempotent — a re-run byte-exactly
# reproduces the artifact (verified via --verify) or fails closed.
#
# Usage: scripts/affidavit_wasm_build.sh [--verify]
#   (no flag)  build (if needed) + copy + write sha256
#   --verify   re-hash the seeded artifact, exit 0 if it matches affidavit.sha256, 1 otherwise
#
# Exit codes: 0 ok, 1 verify mismatch/build failure, 3 loud SKIP (env unmet).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SMALT_AFFIDAVIT_SRC:-$ROOT/../affidavit/affidavit-wasm}"
TARGET="wasm32-wasip1"
DEST_DIR="$ROOT/priv/wasm"
ART="$DEST_DIR/affidavit_wasm.wasm"
SUM="$DEST_DIR/affidavit.sha256"

log() { printf '[affidavit-wasm] %s\n' "$*"; }

fail_closed() { log "FAIL: $*"; exit 1; }

# --- loud SKIP when env unmet (never a faked pass) -------------------------
if [[ "${1:-}" == "--verify" ]]; then
  [[ -f "$ART" ]] || { log "SKIP: no seeded artifact at $ART"; exit 3; }
  [[ -f "$SUM" ]] || { log "SKIP: no sidecar $SUM"; exit 3; }
  log "verifying $ART"
  if (cd "$DEST_DIR" && shasum -a 256 -c affidavit.sha256) >/dev/null 2>&1; then
    log "PASS: sha256 byte-exact"
    exit 0
  fi
  fail_closed "sha256 mismatch for $ART (artifact drifted from $SUM)"
fi

command -v cargo >/dev/null 2>&1 || { log "SKIP: cargo not on PATH"; exit 3; }
[[ -d "$SRC" ]] || { log "SKIP: source crate missing: $SRC"; exit 3; }
if ! rustup target list --installed 2>/dev/null | grep -q "^${TARGET}$"; then
  log "SKIP: rust target $TARGET not installed (rustup target add $TARGET)"
  exit 3
fi

# --- idempotent build ------------------------------------------------------
mkdir -p "$DEST_DIR"
log "building $SRC (target $TARGET)"
if ! (cd "$SRC" && cargo build --lib --target "$TARGET" --profile wasm); then
  fail_closed "cargo build failed for $SRC"
fi
OUT="$SRC/target/$TARGET/wasm/affidavit_wasm.wasm"
[[ -f "$OUT" ]] || fail_closed "cargo produced no artifact at $OUT"

cp "$OUT" "$ART"
(cd "$DEST_DIR" && shasum -a 256 affidavit_wasm.wasm > affidavit.sha256)
log "seeded $ART + $SUM"
(cd "$DEST_DIR" && shasum -a 256 -c affidavit.sha256 >/dev/null) \
  || fail_closed "post-copy hash check failed"
log "PASS"
