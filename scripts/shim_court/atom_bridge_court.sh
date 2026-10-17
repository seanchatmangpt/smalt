#!/usr/bin/env bash
# atom_bridge_court.sh — KD-45 shim court (mutate lane 272, v26.10.16).
#
# Subject: lib/smalt/messaging/amqp/atom_bridge.ex — the ATOM+XML management
# bridge that serves ServiceBusAdministrationClient on the AMQP broker port
# (KD-45 CLOSED-SIMULATED, witness receipt r178e-census-replay-repair.md).
# No court covered it; this one proves it non-vacuous:
#
#   BASELINE  sha256(atom_bridge.ex)
#   BEFORE    real-TCP witness: PUT /{queue}?api-version=... with an ATOM
#             QueueDescription body over a loopback socket into
#             AtomBridge.serve/2 returns 201 + the full 12-field
#             QueueDescription XML (LockDuration parsed from the body).
#   SHIM      neuter the PUT dispatch clause (falls through to the 405
#             catch-all), marked `# SHIM-COURT: KD-45 bridge neutered`.
#   AFTER     the same witness must observe 405 MethodNotAllowed — a 201
#             here would mean the shim was inert (vacuous, [FAIL:AFTER]).
#   RESTORE   sha256 byte-exact, fail-closed.
#
# Never touches connection.ex or any sibling-lane hunk; git is not used.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 2
source "scripts/shim_court/lib.sh"

export SUBJECT="lib/smalt/messaging/amqp/atom_bridge.ex"
export WITNESS="scripts/shim_court/atom_bridge_witness.exs"
# Lane-local build root for the mix legs; EXPORTED because with_shim runs the
# witnesses via bash -c (unexported vars arrive empty there).
export MIX_BUILD_ROOT="${MIX_BUILD_ROOT:-_build-lane272}"

[ -f "$WITNESS" ] || shim_court_skip "witness not found: $WITNESS"
command -v mix >/dev/null || shim_court_skip "mix not on PATH"

shim_court_self_check || { echo "[FAIL:SELF-CHECK]" >&2; exit 1; }

apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys, os, time
p = sys.argv[1]
s = open(p).read()
# Neuter the PUT dispatch clause: retitle its head so PUT falls through to
# the catch-all 405 clause. The whole clause body stays (it becomes dead).
old = 'defp dispatch("PUT", path, body) do'
if old not in s:
    sys.exit("PUT dispatch clause head not found (subject drifted)")
s = s.replace(old, 'defp dispatch(:shim_court_neutered, path, body) do # SHIM-COURT: KD-45 bridge neutered')
open(p, "w").write(s)
# SHIM-COURT: force the compiler to see the edit (same-second rewrites are
# invisible to mix change detection — witnessed in eh_mgmt/etag courts).
os.utime(p, (time.time() + 2, time.time() + 2))
print("[SHIM] AtomBridge PUT dispatch neutered -> 405 catch-all (SHIM-COURT)")
PYEOF
}

# Compile retry (wait out transient sibling-lane breaks) then the real-TCP
# witness with the requested mode. Returns the witness rc.
run_witness() {
    local i=0 out
    until out="$(mix compile 2>&1)"; do
        echo "$out" | grep -q "Compilation error" || {
            echo "[court] tree does not compile:" >&2; tail -20 <<<"$out" >&2; return 1; }
        i=$((i+1)); [ $i -lt 40 ] || {
            echo "[court] tree did not compile within 10 min — flip would be fake" >&2; return 1; }
        echo "[court] waiting out sibling compile break (poll $i)"; sleep 15
    done
    WITNESS_MODE="$1" mix run --no-start "$WITNESS" 2>&1
}

before_witness() {
    local out
    out="$(run_witness before)" || {
        echo "[FAIL:BEFORE] witness failed on the LANDED tree:" >&2
        tail -20 <<<"$out" >&2
        return 1
    }
    echo "$out"
}

# AFTER: under the shim, PUT must degrade to the typed 405 — the flip is the
# non-vacuity proof. A green witness here means the shim was inert.
after_witness() {
    local out
    if out="$(run_witness after)"; then
        echo "$out"
    else
        echo "[FAIL:AFTER] witness failed under the shim (expected 405 flip):" >&2
        tail -20 <<<"$out" >&2
        return 1
    fi
}

# Sibling lanes share this checkout: serialize the shim/restore cycle on this
# subject (two interleaved cycles were witnessed as a flapping baseline sha).
exec 9>>"/tmp/smalt-shim-court-$(basename "$SUBJECT").lock"
flock 9

with_shim "$SUBJECT" \
    "$(declare -f run_witness before_witness); before_witness" \
    "$(declare -f run_witness after_witness); after_witness"
