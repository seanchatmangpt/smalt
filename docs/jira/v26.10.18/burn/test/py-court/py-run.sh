#!/usr/bin/env bash
# Python reality court runner: idempotent venv + real PyPI SDKs, boots its
# own substrate, 180s watchdog, fail-closed. Exit 0 only if every probe
# passed AND the stop-substrate control failed as expected.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$REPO/test/py-court"
VENV="$HERE/.venv"
PID_FILE="/tmp/smalt-py-court.pid"
LOG="$HERE/.logs/substrate.log"
WATCHDOG_SECS=180

export MIX_ENV=test
# Pin the canonical court ports: config/test.exs defaults every listener to a
# probed-free ephemeral port under MIX_ENV=test (test isolation), but this
# runner owns 9443/9444/8443/5672/5673 exclusively (its port gate enforces it)
# and probes those exact ports. SMALT_TEST_*_PORT is the documented override.
export SMALT_TEST_ARM_PORT=9443
export SMALT_TEST_ARM_TLS_PORT=9444
export SMALT_TEST_EGRESS_PORT=8443
export SMALT_TEST_AMQP_PORT=5672
export SMALT_TEST_EVENT_HUBS_PORT=5673

echo "[py-court] repo: $REPO"

# --- 1. venv + real PyPI SDKs (idempotent) --------------------------------
if [ ! -x "$VENV/bin/python" ]; then
  echo "[py-court] creating venv at $VENV"
  python3 -m venv "$VENV" || { echo "[py-court] venv create FAILED"; exit 3; }
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
if ! python -c "import azure.identity, azure.cosmos, azure.storage.blob, azure.servicebus, azure.eventhub, azure.keyvault.keys, requests" 2>/dev/null; then
  echo "[py-court] installing real SDKs from PyPI"
  pip install --quiet --disable-pip-version-check -r "$HERE/requirements.txt" \
    || { echo "[py-court] pip install FAILED"; exit 3; }
fi

# --- 2. ports must be free ------------------------------------------------
for port in 9443 8443 5672 5673; do
  if lsof -ti tcp:"$port" >/dev/null 2>&1; then
    echo "[py-court] port $port occupied. Remediation: lsof -ti tcp:$port | xargs kill -9"
    exit 3
  fi
done

# --- 3. boot substrate with pinned SB shared key + MAA baseline -----------
mkdir -p "$HERE/.logs"
SB_SHARED_KEY="$(python3 -c 'import os,base64;print(base64.b64encode(os.urandom(48)).decode())')"
MAA_MEASUREMENT="$(python3 -c 'import os;print(os.urandom(32).hex())')"
: > "$LOG"
echo "[py-court] booting substrate (9443/8443/5672/5673)..."
mix run --no-halt \
  -e "Application.put_env(:smalt, :sb_shared_key, \"$SB_SHARED_KEY\"); Application.put_env(:smalt, :maa_measurement_baseline, [\"$MAA_MEASUREMENT\"])" \
  >>"$LOG" 2>&1 &
SUB_PID=$!
echo "$SUB_PID" > "$PID_FILE"

cleanup() {
  kill "$SUB_PID" 2>/dev/null
  for _ in $(seq 1 25); do kill -0 "$SUB_PID" 2>/dev/null || break; sleep 0.2; done
  kill -9 "$SUB_PID" 2>/dev/null
  rm -f "$PID_FILE"
}
trap cleanup EXIT

# --- 4. poll until 9443 + 8443 + 5672 accept ------------------------------
up=0
for _ in $(seq 1 120); do
  a=$(nc -z -w 1 127.0.0.1 9443 2>/dev/null && echo y || echo n)
  b=$(nc -z -w 1 127.0.0.1 8443 2>/dev/null && echo y || echo n)
  c=$(nc -z -w 1 127.0.0.1 5672 2>/dev/null && echo y || echo n)
  [ "$a" = y ] && [ "$b" = y ] && [ "$c" = y ] && { up=1; break; }
  kill -0 "$SUB_PID" 2>/dev/null || { echo "[py-court] substrate died during boot; log: $LOG"; tail -20 "$LOG"; exit 2; }
  sleep 0.5
done
[ "$up" = 1 ] || { echo "[py-court] substrate never came up; log: $LOG"; tail -30 "$LOG"; exit 2; }
echo "[py-court] substrate up (pid $SUB_PID)"

# --- 4b. ownership precheck: the substrate on these ports must carry OUR
# MAA baseline and SB key (another lane's substrate can steal the ports
# between the free-check and bind). Attest with OUR measurement: 200 = ours.
own=$(SB_SHARED_KEY="$SB_SHARED_KEY" MAA_MEASUREMENT="$MAA_MEASUREMENT" python3 - <<'PYOWN'
import os, requests
res = requests.post("http://127.0.0.1:8443/attest/sevsnpvm",
                    json={"measurement": os.environ["MAA_MEASUREMENT"]}, timeout=10)
print("ours" if res.status_code == 200 else f"foreign({res.status_code})")
PYOWN
)
if [ "$own" != "ours" ]; then
  echo "[py-court] FATAL: port holders are a foreign substrate (attest probe: $own)."
  echo "          Another lane's substrate stole the canonical ports. Retrying later."
  exit 3
fi
echo "[py-court] ownership verified (attest 200 with our baseline)"

# --- 5. 180s watchdog -----------------------------------------------------
( sleep "$WATCHDOG_SECS"; echo "[py-court] WATCHDOG ${WATCHDOG_SECS}s expired"; kill -9 "$SUB_PID" 2>/dev/null; kill -9 $$ 2>/dev/null ) &

# --- 6. run the court -----------------------------------------------------
export SB_SHARED_KEY MAA_MEASUREMENT
# Dev TLS cert (minted by the substrate at boot) for any https/9444 client.
[ -f "$REPO/tmp/dev-cert.pem" ] && export REQUESTS_CA_BUNDLE="$REPO/tmp/dev-cert.pem"
set +e
python "$HERE/py_reality_test.py"
PY_RC=$?
set -e
kill %2 2>/dev/null || true

# --- 7. stop-substrate control: same STS credential must now FAIL ---------
kill "$SUB_PID" 2>/dev/null
for _ in $(seq 1 50); do
  nc -z -w 1 127.0.0.1 9443 2>/dev/null || break
  sleep 0.2
done
if nc -z -w 1 127.0.0.1 9443 2>/dev/null; then
  echo "[py-court] substrate still holding 9443 after kill; control run inconclusive"
  exit 3
fi
echo "[py-court] substrate stopped — running dead-substrate control"
python - <<'PYCTRL'
import os
from azure.identity import ClientSecretCredential
cred = ClientSecretCredential(
    tenant_id="00000000-0000-0000-0000-000000000000",
    client_id="py-court-client",
    client_secret="py-court-secret",
    authority="https://localhost:9444/",
)
try:
    cred.get_token("https://management.azure.com/.default")
    print("CONTROL-FAIL: token succeeded with the substrate down")
    raise SystemExit(1)
except Exception as exc:
    print(f"CONTROL-OK: refused with substrate down: {type(exc).__name__}")
    raise SystemExit(0)
PYCTRL
CTRL_RC=$?

echo "[py-court] python suite exit: $PY_RC ; control exit: $CTRL_RC"
if [ "$PY_RC" = 0 ] && [ "$CTRL_RC" = 0 ]; then
  echo "[py-court] COURT PASS"
  exit 0
fi
echo "[py-court] COURT FAIL"
exit 1
