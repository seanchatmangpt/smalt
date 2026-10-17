#!/usr/bin/env bash
# GAP-AUD1-01 comp-whitelist mutation court (lane W-5, v26.10.14).
# BASELINE -> AFTER(landed fix holds) -> SHIM(disable the comp whitelist) ->
# BEFORE(corruption witnessed) -> RESTORE(sha256 byte-exact).
# Proves the GAP-AUD1-01 fix NON-VACUOUS: disabling the whitelist reproduces
# the AUD-1 headline corruption class (unimplemented comp overwrites the blob
# body). Falsifier: docs/audit/sections/aud1-blob-cosmos.md GAP-AUD1-01.
# Usage: scripts/shim_court/comp_whitelist_court.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ROUTER="lib/smalt/egress_router.ex"
WITNESS=(env MIX_ENV=test mix run --no-start scripts/shim_court/comp_whitelist_witness.exs)

# Shared-checkout courtesy (compile-freeze SLA): the tree may be mid-edit when
# the court starts; wait (bounded) for a green compile, never shim a broken tree.
for _ in $(seq 1 30); do
  if MIX_ENV=test mix compile >/dev/null 2>&1; then break; fi
  sleep 5
done

base="$(shim_court_sha "$ROUTER")"
shim_court_log COURT "comp-whitelist court subject: $ROUTER"
shim_court_log SHIM "baseline sha256($ROUTER) = $base"
bak="$(mktemp)"
cp "$ROUTER" "$bak"

restore() {
  cp "$bak" "$ROUTER"
  if [ "$(shim_court_sha "$ROUTER")" = "$base" ]; then
    shim_court_log RESTORE "byte-exact restore verified (sha256 match)"
  else
    shim_court_fail RESTORE "restore sha256 mismatch"
  fi
}

# --- Phase 1: AFTER (landed behavior must hold) ------------------------------
if ! "${WITNESS[@]}" after >/dev/null 2>&1; then
  restore
  shim_court_fail AFTER "after-witness failed on the LANDED router (fix absent or regressed)"
fi
shim_court_log AFTER "landed whitelist holds: all unimplemented comps -> typed 400, body unchanged"

# --- Phase 2: SHIM (disable the whitelist) ------------------------------------
apply_shim() {
  python3 - "$ROUTER" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
# R124 collapsed unhandled_blob_comp?/2 into the shared unhandled_comp?/2
# helper (called from every blob/container arm). Anchor on the helper head —
# unique, stable — and prepend a catch-all clause that always reports
# "unhandled", bypassing every whitelist call site at once.
anchor = '  defp unhandled_comp?(conn, allowed) do'
assert s.count(anchor) == 1, "comp-whitelist anchor not found: " + anchor
shim = ('  defp unhandled_comp?(_conn, _allowed), do: false '
        '# SHIM-COURT: whitelist disabled (corruption class re-introduced)\n')
s = s.replace(anchor, shim + anchor)
open(p, "w").write(s)
PYEOF
}

if ! apply_shim; then
  restore
  shim_court_fail SHIM "could not apply shim (anchor drift?)"
fi
if ! MIX_ENV=test mix compile >/dev/null 2>&1; then
  restore
  shim_court_fail SHIM "shimmed tree failed to compile"
fi
shim_court_log SHIM "whitelist disabled at the shared unhandled_comp?/2 helper (all arms)"

# --- Phase 3: BEFORE (corruption must be witnessed on the shimmed tree) ------
if ! "${WITNESS[@]}" before >/dev/null 2>&1; then
  restore
  shim_court_fail BEFORE "corruption NOT witnessed under shim — gate would be vacuous"
fi
shim_court_log BEFORE "corruption witnessed: comp=snapshot overwrote the blob body via the generic Put Blob fallback"

# --- Phase 4: RESTORE ---------------------------------------------------------
restore
shim_court_log COURT "PASS: GAP-AUD1-01 comp-whitelist gate is NON-VACUOUS"
exit 0
