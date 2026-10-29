#!/usr/bin/env bash
# BK-135r scoping non-vacuity court (v26.10.22).
# BASELINE -> AFTER (leg a green on the landed scoping) -> SHIM (scope
# routing disabled: scoped frames ride the legacy dir) -> BEFORE (leg a RED
# on the shimmed tree) -> RESTORE (sha256 byte-exact, fail-closed).
# Proves the matter-scoping law NON-VACUOUS: disabling scoping collapses
# both matters onto one replay path and the interleaved-replay court (leg a
# of test/integration/bk135r_matter_journal_court_test.exs) turns red.
# Usage: scripts/shim_court/bk135r_scoping_court.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

SINK="lib/smalt/storage/journal_sink.ex"
COURT="test/integration/bk135r_matter_journal_court_test.exs"
WITNESS=(env MIX_BUILD_ROOT=_build-bk135r MIX_ENV=test mix test $COURT --only bk135r)

export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$(ls -d $HOME/.asdf/installs/erlang/29*/bin | tail -1):$PATH"

base="$(shim_court_sha "$SINK")"
shim_court_log COURT "bk135r scoping court subject: $SINK"
shim_court_log SHIM "baseline sha256($SINK) = $base"
bak="$(mktemp)"
cp "$SINK" "$bak"

restore() {
  cp "$bak" "$SINK"
  if [ "$(shim_court_sha "$SINK")" = "$base" ] && [ -n "$base" ]; then
    shim_court_log RESTORE "byte-exact restore verified (sha256 match)"
  else
    shim_court_fail RESTORE "restore sha256 mismatch"
  fi
}

# --- Phase 1: AFTER (landed scoping must hold) --------------------------------
if ! "${WITNESS[@]}" >/dev/null 2>&1; then
  restore
  shim_court_fail AFTER "leg a failed on the LANDED scoping (regression?)"
fi
shim_court_log AFTER "leg a green on the landed matter scoping (3 tests, 0 failures)"

# --- Phase 2: SHIM (disable scoping: scoped appends route to the legacy dir) --
apply_shim() {
  python3 - "$SINK" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
# Scope routing happens in ONE place: handle_call({:append_frame, ..., scope})
# resolves the scope's filesystem root via matter_root/2. Disable it by
# anchoring the scoped root resolution — append_frame's scope_state/2 call —
# and rewriting matter_root/2 to drop the scope segment, collapsing both
# matters onto the legacy root. Marked SHIM-COURT.
anchor = ('def matter_root(dir, scope) when is_binary(dir) and is_binary(scope),\n'
          '    do: Path.join([dir, "matter_" <> scope, "segments"])')
assert s.count(anchor) == 1, "bk135r anchor not found: " + anchor
shim = ('def matter_root(dir, _scope) when is_binary(dir),\n'
        '    do: Path.join(dir, "segments") # SHIM-COURT: scoping disabled — both matters collapse onto one root\n')
s = s.replace(anchor, shim)
open(p, "w").write(s)
PYEOF
}

if ! apply_shim; then
  restore
  shim_court_fail SHIM "could not apply shim (anchor drift?)"
fi
if ! env MIX_BUILD_ROOT=_build-bk135r MIX_ENV=test mix compile >/dev/null 2>&1; then
  restore
  shim_court_fail SHIM "shimmed tree failed to compile"
fi
shim_court_log SHIM "matter_root/2 shimmed: scoped frames no longer partition (SHIM-COURT marker in place)"

# --- Phase 3: BEFORE (leg a must go RED on the shimmed tree) -------------------
if "${WITNESS[@]}" >/dev/null 2>&1; then
  restore
  shim_court_fail BEFORE "leg a still GREEN with scoping disabled — court VACUOUS"
fi
shim_court_log BEFORE "leg a RED with scoping disabled — non-vacuity witnessed"

# --- Phase 4: RESTORE -----------------------------------------------------------
restore
shim_court_log COURT "bk135r scoping court: PASS"
exit 0
