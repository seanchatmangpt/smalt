#!/usr/bin/env bash
# X-1 block-commit mutation court (lane X-1, v26.10.14).
# BASELINE -> AFTER(landed fix) -> SHIM(reintroduce the B-5 corruption) ->
# BEFORE(shimmed: corruption witnessed) -> RESTORE(sha256 byte-exact).
# Proves the X-1 fix NON-VACUOUS: dropping the block arms reproduces the
# P0 data corruption (blob body == commit request XML).
# Usage: scripts/shim_court/blocklist_court.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ROUTER="lib/smalt/egress_router.ex"
WITNESS=(env MIX_ENV=test mix run --no-start scripts/shim_court/blocklist_witness.exs)

# Shared-checkout courtesy: the router lane's compile-freeze SLA means the
# tree may be mid-edit when the court starts; wait (bounded) for a green
# compile before baselining, never shim onto a broken tree.
for _ in $(seq 1 30); do
  if MIX_ENV=test mix compile >/dev/null 2>&1; then break; fi
  sleep 5
done
if ! MIX_ENV=test mix compile >/dev/null 2>&1; then
  # SHIM-COURT: compile never went green within the wait window; never shim
  # a broken tree (typed failure, cf. eh_mgmt_court.sh compile guard).
  shim_court_fail COMPILE \
    "mix compile still failing after 30x5s — refusing to baseline/shim a broken tree"
fi

base="$(shim_court_sha "$ROUTER")"
shim_court_log COURT "blocklist court subject: $ROUTER"
shim_court_log SHIM "baseline sha256($ROUTER) = $base"
bak="$(mktemp)"
cp "$ROUTER" "$bak"

# --- Phase 2: AFTER (landed behavior must hold) ------------------------------
if ! "${WITNESS[@]}" after >/dev/null 2>&1; then
  cp "$bak" "$ROUTER"
  rm -f "$bak"
  shim_court_fail AFTER "after-witness failed on the LANDED router (fix absent?)"
fi
shim_court_log SHIM "AFTER witness passed (byte-equality + application/xml on landed code)"

# --- Phase 3: SHIM (reintroduce the pre-fix behavior) -------------------------
apply_shim() {
  python3 - "$ROUTER" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'if conn.query_params["comp"] in ["block", "blocklist"] do'
assert s.count(old) == 1, "block-arm dispatch anchor not found"
s = s.replace(old, 'if false do # SHIM-COURT: revert to pre-X-1 fallback (corruption re-introduced)')
open(p, "w").write(s)
PYEOF
}
if ! apply_shim; then
  cp "$bak" "$ROUTER"
  rm -f "$bak"
  shim_court_fail SHIM "shim failed; router restored from backup"
fi
if ! grep -q 'SHIM-COURT' "$ROUTER"; then
  cp "$bak" "$ROUTER"
  rm -f "$bak"
  shim_court_fail SHIM "shimmed router carries no SHIM-COURT marker"
fi
shim_court_log SHIM "shim applied (block arms disabled; SHIM-COURT marker present)"

# Defeat same-second mtime so Mix recompiles the shimmed source.
sleep 1

# --- Phase 4: BEFORE (old signature must hold under the shim) -----------------
if ! "${WITNESS[@]}" before >/dev/null 2>&1; then
  cp "$bak" "$ROUTER"
  restored="$(shim_court_sha "$ROUTER")"
  if [ "$restored" != "$base" ]; then
    shim_court_fail RESTORE "restore after BEFORE failure did NOT verify (base $base)"
  fi
  rm -f "$bak"
  shim_court_fail BEFORE "before-witness failed on the SHIMMED router — corruption not witnessed; fix vacuous?"
fi
shim_court_log SHIM "BEFORE witness passed (corruption re-witnessed under shim)"

# --- Phase 5: RESTORE ----------------------------------------------------------
cp "$bak" "$ROUTER"
rm -f "$bak"
restored="$(shim_court_sha "$ROUTER")"
if [ "$restored" != "$base" ]; then
  shim_court_fail RESTORE "sha256 mismatch after restore: $restored != $base — $ROUTER CORRUPTED"
fi
shim_court_log SHIM "RESTORE verified byte-exact (sha256 match)"

printf '[PASS] %s: non-vacuous (AFTER landed outcome, BEFORE shimmed corruption, restore verified)\n' \
  "blocklist_court"
