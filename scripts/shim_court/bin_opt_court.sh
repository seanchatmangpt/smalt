#!/usr/bin/env bash
# bin_opt_court.sh — non-vacuity court for scripts/bin_opt_gate.sh (spec §4).
#
# Proves the bin_opt gate is NOT vacuous via the shim-court protocol, on a
# SCRATCH AoQ-shaped fixture module (no lib/ edits, no git, byte-exact restore):
#
#   BEFORE: fixture is a clean context-chained binary match; the gate
#           (BINOPT_SCOPE pointed at the scratch fixture dir) exits 0.
#   SHIM:   injects a deliberately NON-reusable match (match splits the
#           binary, then the same binary feeds :binary.part/3 — measured to
#           emit "BINARY CREATED: ... doesn't support context reuse" on
#           OTP 29). Edits marked SHIM-COURT.
#   AFTER:  the gate REFUSES (exit 1). The flip IS the non-vacuity proof.
#           A gate that accepts the shim exits 1 as VACUOUS GATE.
#   RESTORE: byte-exact (sha256 equal to baseline), fail-closed.
#
# Compile wait is a blocking subprocess (bounded poll on the build artifact
# by construction — mix/elixirc exit when the beam exists or fails loud);
# no Process.sleep anywhere in this court.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/scripts/bin_opt_gate.sh"
export GATE
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bin_opt_court.XXXXXX")"
mkdir -p "$SCRATCH_DIR/scope"
SUBJECT="$SCRATCH_DIR/scope/bin_opt_court_fixture.ex"
export BINOPT_SCOPE="$SCRATCH_DIR/scope"
export BINOPT_BUILD_ROOT="$ROOT/tmp/bin-opt/build"
export BINOPT_RECEIPT_DIR="$SCRATCH_DIR/receipt"
export BINOPT_COURT="1"

cleanup() { [ "${SHIM_COURT_KEEP:-0}" = "1" ] || rm -rf "$SCRATCH_DIR"; }
trap cleanup EXIT

shim_court_self_check

# --- fixture: clean, context-chained, zero FAIL-class warnings --------------
printf '%s\n' \
    'defmodule BinOptCourtFixture do' \
    '  @doc "SHIM-COURT fixture: clean context-chained binary match."' \
    '  def parse(<<type, rest::binary>>) do' \
    '    {type, rest}' \
    '  end' \
    'end' \
    > "$SUBJECT"

before() { bash "$GATE" >/dev/null; }
after() {
    if bash "$GATE" >/dev/null 2>&1; then
        echo "[FAIL] bin_opt gate ACCEPTED the non-reusable match shim — VACUOUS GATE" >&2
        return 1
    fi
    return 0
}

apply_shim() {
    # Measured on OTP 29 / Elixir 1.20.4: match then :binary.part on the same
    # binary emits "BINARY CREATED: ... doesn't support context reuse" (FAIL
    # class). Marker required by lib.sh.
    cat >> "$SHIM_FILE" <<'EOF'
  @doc "SHIM-COURT: deliberately non-reusable binary match (gate must refuse)."
  def non_reusable(bin) do
    <<type, rest::binary>> = bin
    _ = :binary.part(bin, 0, 2)
    {type, rest}
  end
EOF
}

with_shim "$SUBJECT" "$(declare -f before); before" "$(declare -f after); after"

printf '[bin-opt-court] PASS — gate flipped on injected non-reusable match\n'
