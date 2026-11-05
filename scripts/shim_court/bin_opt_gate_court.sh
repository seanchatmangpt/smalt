#!/usr/bin/env bash
# bin_opt_gate_court.sh — non-vacuity court for scripts/bin_opt_gate.sh (lane C1).
#
# Subject: lib/smalt/aoq/frame.ex (real source file, byte-exact restore).
#   BEFORE  unmodified frame.ex -> bin_opt_gate.sh exits 0 (clean tree passes).
#   SHIM    append a SHIM-COURT-marked defmodule with a deliberately
#           non-reusable binary construction (<<h::binary, t::binary>> where
#           t is a bitstring) -> OTP emits "doesn't support context reuse"
#           under bin_opt_info (measured on elixir 1.20.4-otp-29).
#   AFTER   gate exits 1 AND names the violation — the flip IS the
#           non-vacuity proof.
#   RESTORE byte-exact (sha256), fail-closed, via shim_court/lib.sh with_shim.
#
# Note: the gate warms a dedicated build root on first run (~5 min); warm
# runs are incremental. Exit 0 PASS / 1 FAIL / 3 loud SKIP.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/scripts/bin_opt_gate.sh"
SUBJECT="$ROOT/lib/smalt/aoq/frame.ex"
export GATE SUBJECT

shim_court_self_check

gate_clean() { bash "$GATE" >/dev/null 2>&1; }
gate_violation() {
    local out rc
    out="$(bash "$GATE" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -ne 1 ]; then
        echo "[FAIL] gate rc=$rc on shimmed tree (expected 1) — VACUOUS GATE" >&2
        echo "$out" | tail -5 >&2
        return 1
    fi
    echo "$out" | grep -q "doesn't support context reuse" || {
        echo "[FAIL] gate verdict does not name 'doesn't support context reuse'" >&2
        return 1
    }
    return 0
}

apply_shim() {
    cat >>"$SHIM_FILE" <<'EOF'

defmodule Smalt.Aoq.FrameShimCourt do
  # SHIM-COURT: deliberate non-reusable binary construction to force a
  # bin_opt_info FAIL-class warning ("doesn't support context reuse").
  @spec probe(binary(), binary()) :: binary()
  def probe(h, t) when is_binary(h) and is_binary(t) do
    <<h::binary, t::binary>>
  end
end
EOF
}

with_shim "$SUBJECT" "$(declare -f gate_clean); gate_clean" "$(declare -f gate_violation); gate_violation"

printf '[PASS] bin_opt_gate court: clean tree passes, SHIM-COURT non-reusable binary construction flips gate to 1 naming the violation, restore byte-exact\n'
