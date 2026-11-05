#!/usr/bin/env bash
# MAA nonce-registry entry-cap non-vacuity court (v26.11.5, lane L34).
# KD row: docs/jira/v26.10.14/KNOWN_DIVERGENCES.md KD-176.
#
# Negative-fixture gate (a gate that cannot exit 1 is the failure): proves the
# bounded-intake close condition for KD-176 is LIVE — an over-cap registry
# REFUSED — by transiently disabling the entry cap and requiring the real
# nonce-bounds court to flip to FAIL:
#
#   1. COMPILE   bounded wait for a green compile; never shim a broken tree.
#   2. BASELINE  sha256(lib/smalt/attestation/maa.ex).
#   3. BEFORE    MIX_BUILD_ROOT=_build-lane34 mix test
#                test/internal/bkmaap6_nonce_bounds_court_test.exs -> exit 0
#                (the landed bounds hold: TTL sweep, key cap, entry cap,
#                owner-ref, concurrency).
#   4. SHIM      neutralize enforce_entry_cap/0 (SHIM-COURT marked).
#   5. AFTER     same mix test command MUST now FAIL (exit != 0) — the
#                entry-cap leg watches the table exceed the cap. This flip IS
#                the non-vacuity proof: a gate that accepts an over-cap
#                registry is FAIL:VACUOUS-GATE.
#   6. RESTORE   byte-exact sha256 restore, fail-closed.
#
# Receipt: docs/jira/v26.11.5/receipts/l34-kd176.md.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

MAA="lib/smalt/attestation/maa.ex"
RUN="env MIX_BUILD_ROOT=_build-lane34 asdf exec mix test test/internal/bkmaap6_nonce_bounds_court_test.exs"

# --- Phase 1: bounded compile wait; never shim a broken tree ------------------
for _ in $(seq 1 30); do
  if MIX_BUILD_ROOT=_build-lane34 asdf exec mix compile >/dev/null 2>&1; then break; fi
  sleep 5  # SLEEP-CLASS: POLL-STEP
done
if ! MIX_BUILD_ROOT=_build-lane34 asdf exec mix compile >/dev/null 2>&1; then
  shim_court_fail COMPILE "mix compile still failing after 30x5s — refusing to baseline/shim a broken tree"
fi

base="$(shim_court_sha "$MAA")"
shim_court_log COURT "maa nonce-cap court subject: $MAA"
shim_court_log SHIM "baseline sha256($MAA) = $base"
bak="$(mktemp)"
cp "$MAA" "$bak"

restore() {
  cp "$bak" "$MAA"
  rm -f "$bak"
  if [ "$(shim_court_sha "$MAA")" != "$base" ]; then
    shim_court_fail RESTORE "restore did not verify byte-exact"
  fi
  shim_court_log SHIM "RESTORE verified (sha256 byte-exact)"
}

# --- Phase 2: BEFORE — landed bounds court must pass --------------------------
if ! $RUN >/dev/null 2>&1; then
  restore
  shim_court_fail BEFORE "nonce-bounds court failed on the UNMODIFIED tree — refusing to shim"
fi
shim_court_log SHIM "BEFORE witness passed (bounds court 5/5 on landed tree)"

# --- Phase 3: SHIM — disable the entry cap ------------------------------------
apply_shim() {
  python3 - "$MAA" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """  defp enforce_entry_cap do
    if :ets.info(@nonce_table, :size) >= @nonce_max_entries do
      evict_oldest_consumed()
    end

    :ok
  end"""
assert s.count(old) == 1, "entry-cap anchor not found (exactly once)"
new = """  defp enforce_entry_cap do
    :ok # SHIM-COURT: KD-176 entry cap disabled — over-cap registry accepted
  end"""
s = s.replace(old, new)
open(p, "w").write(s)
PYEOF
}
if ! apply_shim; then
  restore
  shim_court_fail SHIM "apply_shim failed; file restored"
fi
if ! grep -q 'SHIM-COURT' "$MAA"; then
  restore
  shim_court_fail SHIM "shimmed file carries no SHIM-COURT marker"
fi
shim_court_log SHIM "shim applied (entry cap disabled, SHIM-COURT marker present)"

# --- Phase 4: AFTER — the bounds court MUST FAIL on the shimmed tree ----------
# A passing court here means the gate accepts an over-cap registry:
# FAIL:VACUOUS-GATE.
if $RUN >/dev/null 2>&1; then
  restore
  shim_court_fail VACUOUS-GATE "bounds court PASSED with the entry cap disabled — gate is vacuous"
fi
shim_court_log SHIM "AFTER flip witnessed (bounds court FAILS with the cap disabled)"

# --- Phase 5: RESTORE ----------------------------------------------------------
restore

shim_court_self_check
shim_court_log COURT "PASS — KD-176 entry-cap gate is non-vacuous"
exit 0
