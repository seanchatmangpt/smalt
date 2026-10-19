#!/usr/bin/env bash
# kv_challenge_court.sh — KD-15 mutation court (S-3 lane, v26.10.15).
#
# Verdict semantics:
#   BEFORE (KD-15 enrichment + /keys guard disabled) => the real
#     @azure/keyvault-keys client cannot complete the two-step challenge
#     handshake: the legacy plain challenge carries no `resource`, so
#     keyVaultAuthenticationPolicy cannot attach a token and the 401
#     propagates => witness exits 1 with HANDSHAKE_FAIL ... 401.
#   AFTER (KD-15 code present) => two-step handshake completes => witness
#     exits 0 with HANDSHAKE_OK.
#   RESTORE is sha256-verified byte-identical to the pre-court snapshot.
#
# Repairs (audit F3+F5, v26.10.16 repair lane 239):
#   (a) compile() status is captured and checked — a broken compile is a typed
#       FAIL and never counts toward the BEFORE-failure PASS condition.
#   (b) the strip shim asserts >=1 replacement site actually changed.
#   (c) the BEFORE witness failure must be the typed missing-`resource` 401.
#   (d) skips are LOUD: `[SKIP] kv_challenge_court: <reason>` + exit 3.
#   (e) the EXIT-trap restore verifies snapshot presence + sha256, fail-closed.
#
# Substrate: PRIVATE ports (canonical 9443/8443/9444 are contended by
# concurrent lanes); enforce mode; same env surface scripts/substrate.sh uses.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# RETIRED witness (clean-room test reset, 64f6099): the witness file was
# deleted with no verification/ successor yet; the court self-skips loudly
# (exit 3) until a successor witness lands.
WITNESS=""
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
fail() { echo "[court] FAIL: $*" >&2; }
# SHIM-COURT: loud-skip helper — the [SKIP] marker + exit 3 contract
# (scripts/shim_court/lib.sh:46-52). Never a silent/faked pass.
skip_loud() { echo "[SKIP] kv_challenge_court: $1" >&2; exit 3; }
RESTORED=0
RESTORE_FAILED=0
restore_snapshot() {
  if [ "$RESTORED" -eq 0 ]; then
    RESTORED=1
    # SHIM-COURT: trap restore is fail-closed — a missing snapshot file or a
    # post-restore sha256 mismatch must never silently no-op.
    if [ ! -f "$SNAP/bearer.kd15.ex" ] || [ ! -f "$SNAP/egress_router.kd15.ex" ]; then
      fail "trap restore: snapshot missing ($SNAP) — subjects CORRUPTED"
      RESTORE_FAILED=1
      return 1
    fi
    cp "$SNAP/bearer.kd15.ex" "$BEARER"
    cp "$SNAP/egress_router.kd15.ex" "$ROUTER"
    if ! sha256sum -c "$SNAP/sha256.kd15.txt" --status; then
      fail "trap restore: sha256 mismatch after restore — subjects CORRUPTED"
      RESTORE_FAILED=1
      return 1
    fi
    mix compile >/dev/null 2>&1
    log "restore (trap) verified sha256"
  fi
}
trap restore_snapshot EXIT
# SHIM-COURT: compile-status capturing compile. Old form piped output to
# grep/tail so a broken compile's nonzero status was never consumed; now the
# status is checked and a broken compile is a typed failure.
compile() {
  local out rc
  out=$(mix compile 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$out" | grep -vE "^(Compiling|Generated|Waiting)" | tail -12
    fail "mix compile exited $rc"
    return "$rc"
  fi
  echo "$out" | grep -vE "^(Compiling|Generated|Waiting)" | tail -2
  return 0
}

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
  # SHIM-COURT: trust the cert the substrate ACTUALLY serves. Smalt.TLS
  # verify_pair (lib/smalt/tls.ex) rejects CA-signed leaves (pkix_verify with
  # the leaf's own key), so the env pair falls back to a port-keyed self-signed
  # seat cert under tmp/dev-certs/. Extract the live peer cert and pin it as
  # the witness trust anchor — self-signed certs serve as their own anchor.
  local served="$SNAP/served-$phase-ca.pem"
  echo | openssl s_client -connect "127.0.0.1:$SUB_TLS" -servername localhost 2>/dev/null \
    | openssl x509 > "$served" 2>/dev/null
  if [ ! -s "$served" ]; then
    log "FATAL: could not extract served TLS cert from 127.0.0.1:$SUB_TLS"
    return 1
  fi
  out=$(NODE_EXTRA_CA_CERTS="$served" SSL_CERT_FILE="$served" \
        SMALT_ARM="http://127.0.0.1:$SUB_ARM" SMALT_VAULT="https://127.0.0.1:$SUB_TLS" node "$WITNESS" 2>&1)
  rc=$?
  # SHIM-COURT: persist the raw witness output so the verdict can type-check
  # the BEFORE failure shape (missing-`resource` 401), not just the exit code.
  printf '%s\n' "$out" > "$SNAP/witness.$phase.txt"
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
# SHIM-COURT: these refusals are loud SKIPs ([SKIP] marker + exit 3).
grep -q 'put_resp_header("www-authenticate", challenge_value(conn, reason))' "$SNAP/bearer.kd15.ex" \
  || skip_loud "snapshot bearer.ex lacks KD-15 enrichment (degraded snapshot)"
grep -q 'Smalt.Auth.Bearer.send_challenge(conn, "MissingBearerToken")' "$SNAP/egress_router.kd15.ex" \
  || skip_loud "snapshot egress_router.ex lacks the /keys guard (degraded snapshot)"

log "phase BEFORE: strip KD-15 (plain challenge, guard passthrough)"
# SHIM-COURT: the strip must actually change >=1 site per subject file —
# a no-op replace would make the BEFORE leg vacuous (F5). Assert counts.
python3 - "$BEARER" "$ROUTER" <<'PYEOF'
import sys
b_path, r_path = sys.argv[1], sys.argv[2]
B_OLD = '|> put_resp_header("www-authenticate", challenge_value(conn, reason))'
B_NEW = '|> put_resp_header("www-authenticate", ~s(Bearer error="invalid_token", error_description="#{reason}"))'
R_OLD = 'Smalt.Auth.Bearer.send_challenge(conn, "Miss' + 'ingBearerToken")'
R_NEW = "conn"
b = open(b_path).read()
if b.count(B_OLD) < 1:
    print("[court] FAIL: strip shim found 0 bearer.ex enrichment sites", file=sys.stderr)
    sys.exit(2)
r = open(r_path).read()
if r.count(R_OLD) < 1:
    print("[court] FAIL: strip shim found 0 egress_router.ex guard sites", file=sys.stderr)
    sys.exit(2)
open(b_path, "w").write(b.replace(B_OLD, B_NEW))
open(r_path, "w").write(r.replace(R_OLD, R_NEW))
PYEOF
strip_rc=$?
if [ "$strip_rc" -ne 0 ]; then
  substrate_stop
  skip_loud "strip shim replaced nothing (BEFORE leg would be vacuous)"
fi

log "compile BEFORE"
if ! compile; then
  substrate_stop
  fail "BEFORE-phase compile broken — typed FAIL, not a BEFORE-witness failure"
  exit 1
fi

if ! substrate_start BEFORE; then
  substrate_stop
  skip_loud "private substrate not UP (BEFORE)"
fi
witness BEFORE
BEFORE_RC=$?

log "restore AFTER (KD-15) code"
cp "$SNAP/bearer.kd15.ex" "$BEARER"
cp "$SNAP/egress_router.kd15.ex" "$ROUTER"
if ! compile; then
  substrate_stop
  fail "AFTER-phase compile broken"
  exit 1
fi
if ! substrate_start AFTER; then
  substrate_stop
  skip_loud "private substrate not UP (AFTER)"
fi
witness AFTER
AFTER_RC=$?
substrate_stop

log "final restore + sha256 verify"
cp "$SNAP/bearer.kd15.ex" "$BEARER"
cp "$SNAP/egress_router.kd15.ex" "$ROUTER"
if ! compile; then
  fail "final-restore compile broken"
  exit 1
fi

if sha256sum -c "$SNAP/sha256.kd15.txt" --status; then
  log "RESTORE VERIFIED (sha256)"
  RESTORE_OK=0
else
  log "RESTORE MISMATCH"
  RESTORE_OK=1
fi

# SHIM-COURT: the BEFORE failure must be the TYPED failure — the real SDK's
# missing-`resource` 401 surfacing as `HANDSHAKE_FAIL RestError:
# MissingBearerToken` (the resource-less challenge means the policy can never
# attach a token, so the server answers the tokenless GET with the bare 401).
# A SEED_FAIL, ResourceNotFoundError from a stale key, or any other crash
# shape does NOT prove the KD-15 enrichment is load-bearing.
TYPED_BEFORE_OK=0
if [ "$BEFORE_RC" -ne 0 ] && [ -f "$SNAP/witness.BEFORE.txt" ] \
   && grep -q "HANDSHAKE_FAIL" "$SNAP/witness.BEFORE.txt" \
   && grep -q "MissingBearerToken" "$SNAP/witness.BEFORE.txt" \
   && ! grep -q "SEED_FAIL" "$SNAP/witness.BEFORE.txt"; then
  TYPED_BEFORE_OK=1
fi

log "VERDICT: BEFORE_RC=$BEFORE_RC AFTER_RC=$AFTER_RC RESTORE_OK=$RESTORE_OK TYPED_BEFORE=$TYPED_BEFORE_OK"
if [ "$BEFORE_RC" -ne 0 ] && [ "$AFTER_RC" -eq 0 ] && [ "$RESTORE_OK" -eq 0 ] && [ "$TYPED_BEFORE_OK" -eq 1 ]; then
  log "PASS: BEFORE fails with the typed missing-resource 401, AFTER handshake completes, restore sha256-verified"
  exit 0
else
  fail "verdict: BEFORE_RC=$BEFORE_RC AFTER_RC=$AFTER_RC RESTORE_OK=$RESTORE_OK TYPED_BEFORE_OK=$TYPED_BEFORE_OK"
  exit 1
fi
