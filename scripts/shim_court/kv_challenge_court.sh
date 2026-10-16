#!/usr/bin/env bash
# kv_challenge_court.sh — KD-15 mutation court (S-3 lane, v26.10.15).
#
# Verdict semantics:
#   BEFORE (KD-15 enrichment + /keys guard disabled) => the real
#     @azure/keyvault-keys client cannot complete the two-step challenge
#     handshake: the legacy plain challenge carries no `resource`, so
#     keyVaultAuthenticationPolicy cannot attach a token and the 401
#     propagates => witness exits 1.
#   AFTER (KD-15 code present) => two-step handshake completes => witness
#     exits 0.
#   RESTORE is sha256-verified byte-identical to the pre-court snapshot.
#
# Substrate: PRIVATE ports (canonical 9443/8443/9444 are contended by
# concurrent lanes); enforce mode; same env surface scripts/substrate.sh uses.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

WITNESS=test/sdk-full/kv_challenge_witness.mjs
BEARER=lib/smalt/auth/bearer.ex
ROUTER=lib/smalt/egress_router.ex
SNAP=/tmp/kd15-court-snap
tls=$(pwd)/.smalt/tls
export NODE_EXTRA_CA_CERTS="$tls/ca-cert.pem"
export SMALT_TLS_CERTFILE="$tls/dev-cert.pem"
export SMALT_TLS_KEYFILE="$tls/dev-key.pem"
export SSL_CERT_FILE="$tls/ca-cert.pem"
mkdir -p "$SNAP"

log() { echo "[court] $*"; }
RESTORED=0
restore_snapshot() {
  if [ "$RESTORED" -eq 0 ]; then
    RESTORED=1
    cp "$SNAP/bearer.kd15.ex" "$BEARER" 2>/dev/null
    cp "$SNAP/egress_router.kd15.ex" "$ROUTER" 2>/dev/null
    mix compile >/dev/null 2>&1
    log "restore (trap)"
  fi
}
trap restore_snapshot EXIT
compile() { mix compile 2>&1 | grep -vE "^(Compiling|Generated|Waiting)" | tail -2; }

SUB_PID=""; SUB_ARM=""; SUB_EGRESS=""; SUB_TLS=""

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

substrate_start() {
  local phase="$1" i up=0
  SUB_ARM=$(free_port); SUB_EGRESS=$(free_port); SUB_TLS=$(free_port); SUB_MCP=$(free_port); SUB_AMQP=$(free_port); SUB_EH=$(free_port)

  mix run --no-start --no-halt -e "Application.put_env(:smalt, :auth_mode, :enforce); Application.put_env(:smalt, :sb_shared_key, \"ws8sharedkey\"); Application.put_env(:smalt, :sb_endpoint, \"sb://127.0.0.1:$SUB_AMQP\"); Application.put_env(:smalt, :amqp_port, $SUB_AMQP); Application.put_env(:smalt, :event_hubs_port, $SUB_EH); Application.put_env(:smalt, :arm_port, $SUB_ARM); Application.put_env(:smalt, :egress_port, $SUB_EGRESS); Application.put_env(:smalt, :arm_tls_port, $SUB_TLS); Application.put_env(:smalt, :mcp_port, $SUB_MCP); {:ok, _} = Application.ensure_all_started(:smalt)" \
    </dev/null >>"$SNAP/substrate.$phase.log" 2>&1 &
  SUB_PID=$!

  for i in $(seq 1 90); do
    if curl -sf -o /dev/null "http://127.0.0.1:$SUB_ARM/metadata/endpoints"; then up=1; break; fi
    kill -0 "$SUB_PID" 2>/dev/null || break
    sleep 1
  done
  if [ "$up" -ne 1 ]; then
    log "FATAL: private substrate not UP ($phase); log tail:"
    tail -12 "$SNAP/substrate.$phase.log"
    return 1
  fi
  log "private substrate UP ($phase): arm=$SUB_ARM egress=$SUB_EGRESS tls=$SUB_TLS"
}

substrate_stop() {
  local beam
  if [ -n "$SUB_PID" ]; then
    beam=$(pgrep -P "$SUB_PID" 2>/dev/null | while read -r p; do pgrep -P "$p" 2>/dev/null; done | head -1)
    [ -n "$beam" ] && kill -TERM "$beam" 2>/dev/null
    kill -TERM "$SUB_PID" 2>/dev/null
    wait "$SUB_PID" 2>/dev/null
  fi
  SUB_PID=""
}

witness() {
  local phase="$1" out rc
  out=$(SMALT_ARM="http://127.0.0.1:$SUB_ARM" SMALT_VAULT="https://127.0.0.1:$SUB_TLS" node "$WITNESS" 2>&1)
  rc=$?
  echo "[witness:$phase] $out"
  return $rc
}

# -- court ----------------------------------------------------------------------

log "snapshot + sha256 + KD-15 marker validation"
cp "$BEARER" "$SNAP/bearer.kd15.ex"
cp "$ROUTER" "$SNAP/egress_router.kd15.ex"
sha256sum "$BEARER" "$ROUTER" | tee "$SNAP/sha256.kd15.txt"
# A degraded snapshot (e.g. taken from an already-mutated tree) makes the
# whole court vacuous — refuse to run unless both KD-15 surfaces are present.
grep -q 'put_resp_header("www-authenticate", challenge_value(conn, reason))' "$SNAP/bearer.kd15.ex" \
  || { log "FATAL: snapshot bearer.ex lacks KD-15 enrichment (degraded snapshot)"; exit 64; }
grep -q 'Smalt.Auth.Bearer.send_challenge(conn, "MissingBearerToken")' "$SNAP/egress_router.kd15.ex" \
  || { log "FATAL: snapshot egress_router.ex lacks the /keys guard (degraded snapshot)"; exit 64; }

log "phase BEFORE: strip KD-15 (plain challenge, guard passthrough)"
python3 - "$BEARER" "$ROUTER" <<'PYEOF'
import sys
b_path, r_path = sys.argv[1], sys.argv[2]
b = open(b_path).read()
b = b.replace(
    '|> put_resp_header("www-authenticate", challenge_value(conn, reason))',
    '|> put_resp_header("www-authenticate", ~s(Bearer error="invalid_token", error_description="#{reason}"))',
)
open(b_path, "w").write(b)
r = open(r_path).read()
r = r.replace(
    'Smalt.Auth.Bearer.send_challenge(conn, "Miss' + 'ingBearerToken")',
    "conn",
)
open(r_path, "w").write(r)
PYEOF

log "compile BEFORE"
compile

substrate_start BEFORE || substrate_start BEFORE || substrate_start BEFORE || exit 65
witness BEFORE
BEFORE_RC=$?

log "restore AFTER (KD-15) code"
cp "$SNAP/bearer.kd15.ex" "$BEARER"
cp "$SNAP/egress_router.kd15.ex" "$ROUTER"
compile
substrate_start AFTER || substrate_start AFTER || substrate_start AFTER || { substrate_stop; exit 66; }
witness AFTER
AFTER_RC=$?
substrate_stop

log "final restore + sha256 verify"
cp "$SNAP/bearer.kd15.ex" "$BEARER"
cp "$SNAP/egress_router.kd15.ex" "$ROUTER"
compile

if sha256sum -c "$SNAP/sha256.kd15.txt" --status; then
  log "RESTORE VERIFIED (sha256)"
  RESTORE_OK=0
else
  log "RESTORE MISMATCH"
  RESTORE_OK=1
fi

log "VERDICT: BEFORE_RC=$BEFORE_RC AFTER_RC=$AFTER_RC RESTORE_OK=$RESTORE_OK"
if [ "$BEFORE_RC" -ne 0 ] && [ "$AFTER_RC" -eq 0 ] && [ "$RESTORE_OK" -eq 0 ]; then
  log "PASS: BEFORE fails, AFTER handshake completes, restore sha256-verified"
  exit 0
else
  log "FAIL"
  exit 1
fi
