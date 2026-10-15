#!/usr/bin/env bash
# run.sh — s4_oauth_negatives auth-adversary court orchestrator.
#
# Boots substrate A (TLS twin on 9444, secret A), runs the positive control +
# negative matrix (phase a), restarts with substrate B on a DIFFERENT
# :sts_signing_secret (phase b), and presents substrate A's token to B —
# pinning actual behavior per case into receipt.json (the honest gap register
# IS the deliverable).
#
# Exit codes: 0 all cases observed (KNOWN-GAP allowed — it is the register) /
# 1 positive control failed or a case unobservable (NEG_STRICT=1 also fails on
# any KNOWN-GAP) / 2 substrate never came up / 3 harness failure (ports busy,
# missing cert material).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SMALT_CERT_DIR:-$REPO/.smalt/tls}"
CA_CERT="$CERT_DIR/ca-cert.pem"
CERT_FILE="$CERT_DIR/dev-cert.pem"
KEY_FILE="$CERT_DIR/dev-key.pem"
WORK="$HERE/.work"
RECEIPT="$HERE/receipt.json"
SECRET_A="smalt-neg-court-secret-A-0123456789abcdef"
SECRET_B="smalt-neg-court-secret-B-9876543210fedcba"
# Alternate ports by default: the canonical 9443/9444/8443 are frequently held
# by other lanes' substrates on this host; override via SMALT_NEG_*_PORT.
ARM_PORT="${SMALT_NEG_ARM_PORT:-19443}"
ARM_TLS_PORT="${SMALT_NEG_ARM_TLS_PORT:-19444}"
EGRESS_PORT="${SMALT_NEG_EGRESS_PORT:-18443}"
AMQP_PORT="${SMALT_NEG_AMQP_PORT:-15672}"
EH_PORT="${SMALT_NEG_EH_PORT:-15673}"
PORTS=($ARM_PORT $ARM_TLS_PORT $EGRESS_PORT)
POLL_DEADLINE_S=90
SUBSTRATE_PID=""
BOOTED=0
FINAL=0

log() { echo "[s4-oauth-neg] $*"; }
die() { echo "[s4-oauth-neg] ERROR: $*" >&2; exit 3; }

cleanup() {
  if [ -n "$SUBSTRATE_PID" ] && kill -0 "$SUBSTRATE_PID" 2>/dev/null; then
    kill -TERM "$SUBSTRATE_PID" 2>/dev/null
    for _ in $(seq 1 25); do kill -0 "$SUBSTRATE_PID" 2>/dev/null || break; sleep 0.2; done
    kill -KILL "$SUBSTRATE_PID" 2>/dev/null
  fi
  # Scoped port guard: only when we actually booted a substrate, and only
  # listeners on OUR ports (verified free before boot).
  if [ "${BOOTED:-0}" = "1" ]; then
    for p in $ARM_PORT $ARM_TLS_PORT $EGRESS_PORT; do
      lsof -ti tcp:"$p" 2>/dev/null | xargs kill -KILL 2>/dev/null
    done
  fi
}
trap cleanup EXIT
for sig in INT TERM HUP; do trap "cleanup; exit 130" "$sig"; done

port_free() { ! (exec 3<>/dev/tcp/127.0.0.1/$1) 2>/dev/null; }

wait_ports() {
  local deadline=$((SECONDS + POLL_DEADLINE_S))
  while [ "$SECONDS" -lt "$deadline" ]; do
    local up=1
    for p in "${PORTS[@]}"; do port_free "$p" && up=0; done
    [ "$up" = "1" ] && return 0
    sleep 0.5
  done
  echo "[s4-oauth-neg] substrate did not open ${PORTS[*]} within ${POLL_DEADLINE_S}s; log: $1" >&2
  return 2
}

wait_ports_closed() {
  local deadline=$((SECONDS + 15))
  while [ "$SECONDS" -lt "$deadline" ]; do
    local busy=0
    for p in "${PORTS[@]}"; do port_free "$p" || busy=1; done
    [ "$busy" = "0" ] && return 0
    sleep 0.3
  done
  return 1
}

# 0. Preconditions ------------------------------------------------------------
for f in "$CA_CERT" "$CERT_FILE" "$KEY_FILE"; do
  [ -f "$f" ] || die "missing $f — run: bash scripts/gen_dev_cert.sh"
done
for p in "${PORTS[@]}"; do
  port_free "$p" || die "port $p occupied. Remediation: lsof -ti tcp:$p | xargs kill -9"
done
mkdir -p "$WORK"

run_phase() { # $1 phase letter, $2 log suffix
  node --test --test-timeout 90000 "$HERE/oauth_neg.test.mjs" 2>&1 | tee -a "$WORK/phase-$1.log"
  return "${PIPESTATUS[0]}"
}

boot_substrate() { # $1 secret
  local eval_code="Application.put_env(:smalt, :sts_signing_secret, \"$1\"); \
Application.put_env(:smalt, :auth_mode, :enforce); \
Application.put_env(:smalt, :arm_port, $ARM_PORT); \
Application.put_env(:smalt, :arm_tls_port, $ARM_TLS_PORT); \
Application.put_env(:smalt, :egress_port, $EGRESS_PORT); \
Application.put_env(:smalt, :amqp_port, $AMQP_PORT); \
Application.put_env(:smalt, :event_hubs_port, $EH_PORT); \
{:ok, _} = Application.ensure_all_started(:smalt)"
  MIX_ENV=test SMALT_TLS_CERTFILE="$CERT_FILE" SMALT_TLS_KEYFILE="$KEY_FILE" \
    mix run --no-start --no-halt -e "$eval_code" \
    >"$WORK/substrate-$2.log" 2>&1 &
  SUBSTRATE_PID=$!
  BOOTED=1
}

# 1. Phase a — substrate A (secret A) -----------------------------------------
log "booting substrate A (secret A) on ${PORTS[*]}"
boot_substrate "$SECRET_A" a || true
wait_ports "$WORK/substrate-a.log" || { FINAL=2; exit 2; }
log "substrate A up; running phase a (positive control + negative matrix)"
NEG_PHASE=a \
NEG_SECRET_A="$SECRET_A" \
NEG_ARM_HTTP="http://127.0.0.1:$ARM_PORT" \
NEG_ARM_TLS="https://localhost:$ARM_TLS_PORT" \
NEG_EGRESS="http://127.0.0.1:$EGRESS_PORT" \
NEG_TOKEN_A_FILE="$WORK/tokenA.txt" \
NEG_RECEIPT_FILE="$RECEIPT" \
NODE_EXTRA_CA_CERTS="$CA_CERT" \
  run_phase a
PHASE_A_CODE=$?
[ "$PHASE_A_CODE" -ne 0 ] && FINAL=1

# 2. Restart into substrate B (different signing secret) ----------------------
log "stopping substrate A; booting substrate B (secret B)"
cleanup
SUBSTRATE_PID=""
wait_ports_closed || { log "warn: ports not fully closed before B boot"; }
boot_substrate "$SECRET_B" b
wait_ports "$WORK/substrate-b.log" || { FINAL=2; exit 2; }
log "substrate B up; running phase b (cross-secret token presentation)"

# Phase a receipt must be preserved: phase b appends via a merge read.
NEG_PHASE=b \
NEG_SECRET_B="$SECRET_B" \
NEG_ARM_HTTP="http://127.0.0.1:$ARM_PORT" \
NEG_ARM_TLS="https://localhost:$ARM_TLS_PORT" \
NEG_EGRESS="http://127.0.0.1:$EGRESS_PORT" \
NEG_TOKEN_A_FILE="$WORK/tokenA.txt" \
NEG_RECEIPT_FILE="$RECEIPT.phaseb" \
NODE_EXTRA_CA_CERTS="$CA_CERT" \
  run_phase b
PHASE_B_CODE=$?
[ "$PHASE_B_CODE" -ne 0 ] && FINAL=1

# 3. Merge the phase-a and phase-b receipts into the final gap register -------
node - "$RECEIPT" <<'EOF'
const fs = require("fs");
const file = process.argv[2];
let a = { cases: [] }, b = { cases: [] };
try { a = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
try { b = JSON.parse(fs.readFileSync(file + ".phaseb", "utf8")); } catch {}
const merged = { ...b, phases: [a, b] };
merged.cases = [...(a.cases || []), ...(b.cases || [])];
merged.total = merged.cases.length;
merged.knownGaps = merged.cases.filter((c) => c.verdict === "KNOWN-GAP").length;
merged.securityPass = merged.cases.filter((c) => c.verdict === "SECURITY-PASS").length;
fs.writeFileSync(file, JSON.stringify(merged, null, 2) + "\n");
console.log(`[s4-oauth-neg] merged receipt: total=${merged.total} SECURITY-PASS=${merged.securityPass} KNOWN-GAP=${merged.knownGaps} -> ${file}`);
EOF
[ $? -ne 0 ] && FINAL=3
rm -f "$RECEIPT.phaseb" 2>/dev/null

log "done (exit $FINAL). Gap register: $RECEIPT"
exit "$FINAL"
