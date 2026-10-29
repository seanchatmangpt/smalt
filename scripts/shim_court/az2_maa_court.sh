#!/usr/bin/env bash
# AZ-2 MAA measurement cross-binding non-vacuity court (v26.10.22, lane az2).
# AFTER(landed: valid quote attests) -> SHIM(corrupt the runtimeData
# measurement cross-binding) -> BEFORE(shimmed: a TAMPERED measurement is
# ATTESTED — the flip IS the proof the gate is live) -> RESTORE(sha256
# byte-exact).
#
# Proves the KD-167 gate NON-VACUOUS: if same_measurement?/2 stops
# refusing, a tampered measurement byte would be attested and bound into a
# signed JWS. Complement of the ExUnit court
# test/internal/az2_maa_attestation_court_test.exs (7/7).
# KD row: docs/jira/v26.10.14/KNOWN_DIVERGENCES.md KD-167.
# Receipt: docs/jira/v26.10.22/receipts/az2-maa-attestation.md.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

MAA="lib/smalt/attestation/maa.ex"
WITNESS=(env MIX_BUILD_ROOT=_build-az2 asdf exec mix run --no-start scripts/shim_court/az2_maa_witness.exs)

# Shared-checkout courtesy: bounded wait for a green compile before
# baselining — never shim a broken tree (other lanes' in-flight files gate
# this; the wait is bounded, the refusal is typed).
for _ in $(seq 1 30); do
  if MIX_BUILD_ROOT=_build-az2 asdf exec mix compile >/dev/null 2>&1; then break; fi
  sleep 5  # SLEEP-CLASS: POLL-STEP
done
if ! MIX_BUILD_ROOT=_build-az2 asdf exec mix compile >/dev/null 2>&1; then
  shim_court_fail COMPILE "mix compile still failing after 30x5s — refusing to baseline/shim a broken tree"
fi

base="$(shim_court_sha "$MAA")"
shim_court_log COURT "az2 maa court subject: $MAA"
shim_court_log SHIM "baseline sha256($MAA) = $base"
bak="$(mktemp)"
cp "$MAA" "$bak"

# --- Phase 2: AFTER (landed behavior: valid attests, tampered refuses) --------
if ! "${WITNESS[@]}" ok >/dev/null 2>&1; then
  cp "$bak" "$MAA"; rm -f "$bak"
  shim_court_fail AFTER "landed MAA face does not attest a valid measurement"
fi
shim_court_log SHIM "AFTER witness passed (landed MAA attests a valid quote)"

# --- Phase 3: SHIM (corrupt the measurement cross-binding) --------------------
apply_shim() {
  python3 - "$MAA" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "    if is_binary(runtime_hex) and lower(runtime_hex) == Base.encode16(m, case: :lower) do\n      :ok"
assert s.count(old) == 1, "measurement cross-binding anchor not found"
new = ('    if is_binary(runtime_hex) and lower(runtime_hex) == Base.encode16(m, case: :lower) or false == false do\n'
       '      :ok # SHIM-COURT: corrupted measurement cross-binding (AZ-2/KD-167)')
s = s.replace(old, new)
open(p, "w").write(s)
PYEOF
}
if ! apply_shim; then
  cp "$bak" "$MAA"; rm -f "$bak"
  shim_court_fail SHIM "shim failed; maa.ex restored from backup"
fi
if ! grep -q 'SHIM-COURT' "$MAA"; then
  cp "$bak" "$MAA"; rm -f "$bak"
  shim_court_fail SHIM "shimmed maa.ex carries no SHIM-COURT marker"
fi
shim_court_log SHIM "shim applied (measurement cross-binding corrupted; SHIM-COURT marker present)"

sleep 1  # Defeat same-second mtime so Mix recompiles the shimmed source.

# --- Phase 4: BEFORE (shimmed: tampered measurement must be ATTESTED) ---------
# The tamper witness FAILS here (it expects refusal) — its failure is the flip.
if "${WITNESS[@]}" tamper >/dev/null 2>&1; then
  cp "$bak" "$MAA"
  if [ "$(shim_court_sha "$MAA")" != "$base" ]; then
    shim_court_fail RESTORE "restore after BEFORE failure did NOT verify (base $base)"
  fi
  rm -f "$bak"
  shim_court_fail BEFORE "shimmed MAA still refuses tampered measurement — gate vacuous?"
fi
shim_court_log SHIM "BEFORE witness passed (shimmed MAA ATTESTS the tampered measurement — flip witnessed)"

# --- Phase 5: RESTORE ----------------------------------------------------------
cp "$bak" "$MAA"
rm -f "$bak"
restored="$(shim_court_sha "$MAA")"
if [ "$restored" != "$base" ]; then
  shim_court_fail RESTORE "sha256 mismatch after restore: $restored != $base — $MAA CORRUPTED"
fi
shim_court_log SHIM "RESTORE verified byte-exact (sha256 match)"

printf '[PASS] az2_maa_court: non-vacuous (landed attests, shimmed ATTESTS-tampered, restore byte-exact)\n'
