#!/usr/bin/env bash
# AZB-20 anti-vacuity court (TICKETS.md AZB-20): strip x-ms-request-id in the
# ARM router → the control-plane header audit must FAIL. BASELINE → SHIM →
# AFTER → RESTORE (sha256 fail-closed). Exit 0 court passes, 1 fail, 3 skip.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
ROUTER=lib/smalt/arm_gateway/router.ex
BASE=$(sha256sum "$ROUTER" | cut -d' ' -f1)
CAP=tmp/azb20/capture-antivacuity.jsonl
LOG=tmp/azb20/antivacuity-substrate.log

cleanup() {
  for p in 39443 39444 39475 39454; do lsof -ti tcp:$p 2>/dev/null | xargs -r kill -9 2>/dev/null || true; done
}
trap 'cleanup' EXIT

# BASELINE: audited run must PASS (router stamps the header).
# SHIM: comment out the echo plug's put_resp_header.
python3 - "$ROUTER" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = '      put_resp_header(conn, "x-ms-request-id", request_id)'
new = '      # SHIM-COURT AZB-20: put_resp_header(conn, "x-m' + 's-request-id", request_id)'
assert old in s, "request-id plug line not found"
open(p, "w").write(s.replace(old, new))
print("[SHIM] request-id header stripped in arm router")
EOF

restore() {
  python3 - "$ROUTER" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
new = '      # SHIM-COURT AZB-20: put_resp_header(conn, "x-m' + 's-court-removed", request_id)'
old = '      # SHIM-COURT AZB-20: put_resp_header(conn, "x-m' + 's-request-id", request_id)'
assert old in s
open(p, "w").write(s.replace(old, "      put_resp_header(conn, \"x-ms-request-id\", request_id)"))
EOF
}

RESTORED=0
restore_on_err() { [ "$RESTORED" = "0" ] && restore; cleanup; }
trap 'restore_on_err' EXIT

echo "[BASELINE sha256 $BASE]"

# Rebuild + boot control plane with the shim.
MIX_BUILD_ROOT=_build-lane-azb20 MIX_ENV=test mix compile >/dev/null 2>&1
AZB20_PLANES=control AZB20_SB_KEY=dGVzdGtleXRlc3RrZXl0ZXN0a2V5MTIzNA== MIX_ENV=test \
  MIX_BUILD_ROOT=_build-lane-azb20 \
  SMALT_TLS_CERTFILE="$REPO/.smalt/tls/dev-cert.pem" SMALT_TLS_KEYFILE="$REPO/.smalt/tls/dev-key.pem" \
  mix run --no-start --no-halt test/sdk-full/azb20/boot_plane.exs >"$LOG" 2>&1 &
BOOTPID=$!

# Wait for arm port.
for i in $(seq 1 120); do
  if lsof -nP -iTCP:39443 -sTCP:LISTEN >/dev/null 2>&1; then break; fi
  sleep 1
done
lsof -nP -iTCP:39443 -sTCP:LISTEN >/dev/null || { echo "[SKIP] control plane never opened 39443"; exit 3; }
sleep 2

# Recording proxy in AUDIT mode against the shimmed router.
rm -f "$CAP"
SMALT_CERT_DIR="$REPO/.smalt/tls" node test/sdk-full/azb20/recording-proxy.mjs \
  --listen 39454 --target http://127.0.0.1:39443 --plane control --capture "$CAP" >tmp/azb20/antivacuity-proxy.log 2>&1 &
PROXYPID=$!
sleep 2

# Drive traffic through the proxy: mint + a couple of ARM calls.
TOKURL=https://localhost:39454/oauth2/v2.0/token
curl -sk -X POST "$TOKURL" -d "grant_type=client_credentials&client_id=azb20court&client_secret=dev" -o /dev/null
curl -sk -o /dev/null "https://localhost:39454/subscriptions?api-version=2022-12-01"
curl -sk -o /dev/null -X PUT -H "content-type: application/merkle+json" \
  -d '{"location":"westus"}' \
  "https://localhost:39454/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/azb20court?api-version=2021-04-01"
sleep 1

# Stop proxy -> triggers audit.
kill $PROXYPID 2>/dev/null || true
for i in $(seq 1 20); do kill -0 $PROXYPID 2>/dev/null || break; sleep 0.5; done

AUDIT=$(grep -c "HEADER AUDIT FAIL" tmp/azb20/antivacuity-proxy.log || true)
VIOL=$(grep -c "missing x-ms-request-id" tmp/azb20/antivacuity-proxy.log || true)
kill $BOOTPID 2>/dev/null || true
cleanup

# RESTORE fail-closed.
restore
MIX_BUILD_ROOT=_build-lane-azb20 MIX_ENV=test mix compile >/dev/null 2>&1
RESTORED=1
AFTER=$(sha256sum "$ROUTER" | cut -d' ' -f1)
if [ "$AFTER" != "$BASE" ]; then
  echo "RESTORE-DRIFT sha256 $BASE -> $AFTER"; exit 1
fi

if [ "${AUDIT:-0}" -ge 1 ]; then
  echo "[AFTER] header audit FAILED with shim present ($VIOL missing-x-ms-request-id violations) — audit is NON-VACUOUS"
  echo "[RESTORE] sha256 byte-exact: $AFTER"
  exit 0
fi
echo "[AFTER] header audit did NOT fail with the header stripped — audit is VACUOUS"
exit 1
