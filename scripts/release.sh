#!/usr/bin/env bash
# scripts/release.sh — smalt release manufacture (assemble + verify + tar + receipt)
# bash -euo pipefail. No publish step; assemble only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="$(grep -o '@version "[^"]*"' mix.exs | head -1 | cut -d'"' -f2)"
ARCH="$(uname -m)"
TAR_NAME="smalt-${VERSION}-${ARCH}.tar.gz"
REL_DIR="_build/prod/rel/smalt"
LOG="_build/prod/rel-boot.log"

log() { echo "[release] $*"; }
fail() { echo "[release][REFUSED] $*" >&2; exit 1; }

receipt() { # receipt <standing> <detail...>
  local standing="$1"; shift
  log "--- RECEIPT ---"
  log "subject:     smalt ${VERSION} release tarball (${ARCH})"
  log "authority:   scripts/release.sh (assemble-only; no publish)"
  log "consequence: ${standing}"
  log "replay:      python3 scripts/doctor.py && MIX_ENV=prod mix release && bash scripts/release.sh --verify-only"
  for line in "$@"; do log "note:        ${line}"; done
}

# --- (1) Gate: diagnostic court must pass ---
log "gate: python3 scripts/doctor.py"
python3 scripts/doctor.py || fail "doctor court failed (exit $?)"

# --- (2) Build: MIX_ENV=prod mix release (assemble only) ---
log "building MIX_ENV=prod mix release"
ATTEMPT=1
while true; do
  if MIX_ENV=prod mix release --overwrite 2>&1 | tee "$ROOT/_build/prod-release-build.log"; then
    break
  fi
  if [ "$ATTEMPT" -ge 3 ]; then
    fail "mix release failed after ${ATTEMPT} attempts; see _build/prod-release-build.log (likely a concurrent-lane compile break; BLOCKED with the exact compile error above)"
  fi
  log "build attempt ${ATTEMPT} failed; waiting 30s and retrying (${ATTEMPT}/2 retries)"
  ATTEMPT=$((ATTEMPT + 1))
  sleep 30
done
[ -x "$REL_DIR/bin/smalt" ] || fail "release binary missing at $REL_DIR/bin/smalt"

# --- (3) Boot verification: foreground w/ timeout 15s, poll ports ---
# Ports overridable: the release reads :smalt, :arm_port / :egress_port config.
# Without a rel/env.sh.e hook, override at boot via:
#   SMALT_ARM_PORT=9443 SMALT_EGRESS_PORT=8443 bin/smalt foreground
# (requires the releases block in mix.exs to include:
#     include_executables: [:smalt],  applications: [smalt: :permanent]
#  and application.ex already reads Application.get_env(:smalt, :arm_port, 9443),
#  so config can also be pinned in rel/env.sh.e via:
#     export ELIXIR_CFG='/etc/smalt/config.exs'   # or runtime.exs overrides)
log "boot-verifying $REL_DIR/bin/smalt start (foreground; timeout 15s)"
"$REL_DIR/bin/smalt" start >"$LOG" 2>&1 &
BOOT_PID=$!
BOOT_OK=0
for _ in $(seq 1 30); do
  for p in 9443 8443; do
    if lsof -ti tcp:"$p" -s tcp:listen >/dev/null 2>&1; then BOOT_OK=1; break; fi
  done
  [ "$BOOT_OK" = 1 ] && break
  kill -0 "$BOOT_PID" 2>/dev/null || break
  sleep 0.5
done
if [ "$BOOT_OK" = 1 ]; then
  log "boot verified: ports responding; stopping boot process $BOOT_PID"
  "$REL_DIR/bin/smalt" stop >/dev/null 2>&1 || true
  sleep 1
  kill "$BOOT_PID" 2>/dev/null || true
  wait "$BOOT_PID" 2>/dev/null || true
else
  "$REL_DIR/bin/smalt" stop >/dev/null 2>&1 || true
  kill "$BOOT_PID" 2>/dev/null || true
  wait "$BOOT_PID" 2>/dev/null || true
  echo "[release][FAILED] release did not open ports 9443/8443 within 15s; boot log:" >&2
  cat "$LOG" >&2
  receipt "FAILED" "boot verification failed; see $LOG"
  exit 1
fi

# --- (4) Tar the release with sha256 ---
mkdir -p tmp
log "packing tmp/$TAR_NAME"
tar -czf "tmp/$TAR_NAME" -C "_build/prod/rel" smalt
SHA256="$(shasum -a 256 "tmp/$TAR_NAME" | awk '{print $1}')"
log "sha256($TAR_NAME) = $SHA256"

# --- (5) Receipt ---
receipt "ALIVE" "tarball: tmp/$TAR_NAME" "sha256: $SHA256" "boot: ports 9443/8443 observed open, then stopped"
