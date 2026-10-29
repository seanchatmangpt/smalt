#!/usr/bin/env bash
# ECOURT wire fence runner — pure Erlang court (test/courts/court_wire.erl).
#
# Usage: scripts/courts/court_wire.sh
# Exit:  0 all legs pass (possibly with loud SKIP) / 1 fence violation /
#        3 loud SKIP (substrate down) / 2 config error.
#
# Zero Elixir helpers: compiles the .erl with erlc and runs it on the stock
# OTP runtime (crypto + ssl apps only). MIX_BUILD_ROOT=_build-ecourt per lane
# law (build artifacts under _build-ecourt/ecourt).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export MIX_BUILD_ROOT=_build-ecourt
export SMALT_CA_FILE="$ROOT/.smalt/tls/ca-cert.pem"
OUT="$ROOT/_build-ecourt/ecourt"
mkdir -p "$OUT"

# -- substrate preflight: loud SKIP if any plane port is down (never restart) -
for port in 5672 9443 9444; do
  if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "[ECOURT-SKIP] substrate port $port not LISTENING — live-substrate court refuses to boot/restart anything. Start with 'just substrate-up' and rerun." >&2
    exit 3
  fi
done

# -- SAS key: resolve the LIVE substrate's actual key --
# The beam boot args carry the literal Application.put_env(:smalt,
# :sb_shared_key, "...") (same user, ps eww). A per-host derivation can
# mismatch an explicitly-keyed boot -> 401 INVALID_LOCAL_SAS that is a
# court-config error, not a fence violation. Falls back to the substrate.sh
# FQDN dev-key derivation for a boot we cannot observe.
SUB_PID="$(cat /private/tmp/smalt-substrate-state/substrate.pid 2>/dev/null || echo 0)"
SB_KEY_FROM_BEAM="$(ps eww "$SUB_PID" 2>/dev/null \
  | grep -o 'Application.put_env(:smalt, :sb_shared_key, "[^"]*"' | head -1 \
  | cut -d'"' -f2)"
if [ -n "$SB_KEY_FROM_BEAM" ]; then
  export SMALT_SB_SHARED_KEY="$SB_KEY_FROM_BEAM"
else
  export SMALT_SB_SHARED_KEY="$(printf '%s' "$(hostname)smalt-dev-sb" | openssl dgst -sha256 -binary | base64)"
fi

# -- compile + run (pure Erlang, no Elixir on the path of the court itself) --
erlc -o "$OUT" "$ROOT/test/courts/court_wire.erl"
erl -noshell -pa "$OUT" -eval 'court_wire:main()' -s init stop
