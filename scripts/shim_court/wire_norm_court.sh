#!/usr/bin/env bash
# S-4 wire-normalization mutation court (KD-01 / KD-03 / KD-07), v26.10.14.
# BASELINE -> AFTER(landed) -> SHIM(one-line revert) -> BEFORE(shimmed) -> RESTORE(sha256-verified).
# Usage: scripts/shim_court/wire_norm_court.sh [kd01|kd03|kd07|all]
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
ROUTER="lib/smalt/egress_router.ex"
BLOB_SERVICE="lib/smalt/data_plane/blob_service.ex"
WITNESS="mix run --no-start scripts/shim_court/wire_norm_witness.exs"
SHIMPY="scripts/shim_court/wire_norm_shim.py"

run_leg() {
  local mode="$1"
  $WITNESS "$mode" >/dev/null 2>&1
}

run_court() {
  local kd="$1" file="$2"
  shim_court_log COURT "=== $kd (subject: $file) ==="

  local base
  base="$(shim_court_sha "$file")"
  shim_court_log SHIM "baseline sha256($file) = $base"
  local bak
  bak="$(mktemp)"
  cp "$file" "$bak"

  if ! run_leg "${kd}_after"; then
    rm -f "$bak"
    shim_court_fail AFTER "$kd: after-witness failed on the LANDED file"
  fi
  shim_court_log SHIM "$kd AFTER passed (Azure shape holds)"

  if ! python3 "$SHIMPY" "$kd" "$file"; then
    cp "$bak" "$file"
    rm -f "$bak"
    shim_court_fail SHIM "$kd: shim failed; file restored"
  fi

  # Defeat same-second mtime: force Mix to see the shimmed source as newer.
  sleep 1

  if ! run_leg "${kd}_before"; then
    cp "$bak" "$file"
    rm -f "$bak"
    shim_court_fail BEFORE "$kd: before-witness failed on the SHIMMED file"
  fi
  shim_court_log SHIM "$kd BEFORE passed (old shape returns)"

  cp "$bak" "$file"
  rm -f "$bak"
  local restored
  restored="$(shim_court_sha "$file")"
  if [ "$restored" != "$base" ]; then
    shim_court_fail RESTORE "$kd: restore sha mismatch"
  fi
  shim_court_log SHIM "$kd RESTORE verified byte-exact"
}

case "${1:-all}" in
  kd01) run_court kd01 "$ROUTER" ;;
  kd03) run_court kd03 "$BLOB_SERVICE" ;;
  kd07) run_court kd07 "$ROUTER" ;;
  all)
    run_court kd01 "$ROUTER"
    run_court kd07 "$ROUTER"
    run_court kd03 "$BLOB_SERVICE"
    ;;
  *)
    shim_court_fail ARGS "usage: wire_norm_court.sh [kd01|kd03|kd07|all]"
    ;;
esac

shim_court_log COURT "WIRE-NORM COURT: ALL LEGS PASSED"
