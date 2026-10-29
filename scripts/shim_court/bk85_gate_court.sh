#!/usr/bin/env bash
# BK-85 seal invariant-gate non-vacuity court (v26.10.22, lane bk85).
# AFTER(landed) -> SHIM(corrupt the gate's host blake3 leg) ->
# BEFORE(shimmed: every seal refuses :invariant_violation) ->
# RESTORE(sha256 byte-exact).
#
# Proves the invariant gate NON-VACUOUS: a corrupted comparison leg flips
# every seal to the typed invariant refusal — the gate is live, not a
# pass-through. Complement of the landed ExUnit court
# test/internal/bk85_seal_invariant_court_test.exs (successful-seal legs).
# Root cause receipt: docs/jira/v26.10.22/receipts/bk85-seal-invariant.md.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ENGINE="lib/smalt/affidavit/wasm_engine.ex"
WITNESS=(env MIX_BUILD_ROOT=_build-bk85 asdf exec mix run --no-start scripts/shim_court/bk85_gate_witness.exs)

# Shared-checkout courtesy: bounded wait for a green compile before
# baselining — never shim a broken tree.
for _ in $(seq 1 30); do
  if MIX_BUILD_ROOT=_build-bk85 asdf exec mix compile >/dev/null 2>&1; then break; fi
  sleep 5  # SLEEP-CLASS: POLL-STEP
done
if ! MIX_BUILD_ROOT=_build-bk85 asdf exec mix compile >/dev/null 2>&1; then
  shim_court_fail COMPILE "mix compile still failing after 30x5s — refusing to baseline/shim a broken tree"
fi

base="$(shim_court_sha "$ENGINE")"
shim_court_log COURT "bk85 gate court subject: $ENGINE"
shim_court_log SHIM "baseline sha256($ENGINE) = $base"
bak="$(mktemp)"
cp "$ENGINE" "$bak"

# --- Phase 2: AFTER (landed behavior must hold: seals succeed) ----------------
if ! "${WITNESS[@]}" ok >/dev/null 2>&1; then
  cp "$bak" "$ENGINE"; rm -f "$bak"
  shim_court_fail AFTER "landed engine does not seal — fix absent or regressed?"
fi
shim_court_log SHIM "AFTER witness passed (landed engine seals)"

# --- Phase 3: SHIM (corrupt the gate's host blake3 leg) -----------------------
apply_shim() {
  python3 - "$ENGINE" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "if raw == binary_part(ctrt, 70, 32), do: :ok, else: {:error, :invariant_violation}"
assert s.count(old) == 1, "gate blake3 comparison anchor not found"
new = ('if raw == binary_part(ctrt, 70, 32) and false, do: :ok, '
       'else: {:error, :invariant_violation} # SHIM-COURT: corrupted host blake3 leg (BK-85 tamper)')
s = s.replace(old, new)
open(p, "w").write(s)
PYEOF
}
if ! apply_shim; then
  cp "$bak" "$ENGINE"; rm -f "$bak"
  shim_court_fail SHIM "shim failed; engine restored from backup"
fi
if ! grep -q 'SHIM-COURT' "$ENGINE"; then
  cp "$bak" "$ENGINE"; rm -f "$bak"
  shim_court_fail SHIM "shimmed engine carries no SHIM-COURT marker"
fi
shim_court_log SHIM "shim applied (host blake3 leg corrupted; SHIM-COURT marker present)"

sleep 1  # Defeat same-second mtime so Mix recompiles the shimmed source.

# --- Phase 4: BEFORE (shimmed: every seal must refuse invariant_violation) ----
if ! "${WITNESS[@]}" tamper >/dev/null 2>&1; then
  cp "$bak" "$ENGINE"
  if [ "$(shim_court_sha "$ENGINE")" != "$base" ]; then
    shim_court_fail RESTORE "restore after BEFORE failure did NOT verify (base $base)"
  fi
  rm -f "$bak"
  shim_court_fail BEFORE "shimmed engine still seals — gate vacuous?"
fi
shim_court_log SHIM "BEFORE witness passed (shimmed engine refuses :invariant_violation)"

# --- Phase 5: RESTORE ----------------------------------------------------------
cp "$bak" "$ENGINE"
rm -f "$bak"
restored="$(shim_court_sha "$ENGINE")"
if [ "$restored" != "$base" ]; then
  shim_court_fail RESTORE "sha256 mismatch after restore: $restored != $base — $ENGINE CORRUPTED"
fi
shim_court_log SHIM "RESTORE verified byte-exact (sha256 match)"

printf '[PASS] bk85_gate_court: non-vacuous (landed seal ok, shimmed gate refuses, restore byte-exact)\n'
