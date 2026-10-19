#!/usr/bin/env bash
# s10 attestation/key-custody adversary court runner: idempotent venv, boots its
# own substrate with a random MAA baseline measurement (M1) in env, 240s
# watchdog, runs adversary.py over real loopback wire, then a dead-substrate
# control. Fail-closed: exit 0 only if every attack held and the substrate
# refuses attestations when dead.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

VENV="$HERE/.venv"
PID_FILE="/tmp/smalt-s10-court.pid"
LOG="$HERE/.logs/substrate.log"
WATCHDOG_SECS=240

export MIX_ENV=test

echo "[s10] repo: $REPO"

# --- 1. venv (idempotent) ---------------------------------------------------
if [ ! -x "$VENV/bin/python" ]; then
  echo "[s10] creating venv at $VENV"
  python3 -m venv "$VENV" || { echo "[s10] venv create FAILED"; exit 3; }
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
if ! python -c "import requests" 2>/dev/null; then
  echo "[s10] installing requests"
  pip install --quiet --disable-pip-version-check requests \
    || { echo "[s10] pip install FAILED"; exit 3; }
fi

# --- 2. ports must be free ---------------------------------------------------
# Private port lane so concurrent courts on the canonical checkout never collide.
ARM_PORT="${ARM_PORT:-39443}"
EGRESS_PORT="${EGRESS_PORT:-38443}"
AMQP_PORT="${AMQP_PORT:-35272}"
EH_PORT="${EH_PORT:-35673}"
TLS_PORT="${TLS_PORT:-39444}"
for port in "$ARM_PORT" "$EGRESS_PORT" "$AMQP_PORT" "$EH_PORT" "$TLS_PORT"; do
  if lsof -ti tcp:"$port" >/dev/null 2>&1; then
    echo "[s10] port $port occupied. Remediation: lsof -ti tcp:$port | xargs kill -9"
    exit 3
  fi
done

# --- 3. boot substrate with MAA baseline M1 ---------------------------------
mkdir -p "$HERE/.logs"
SB_SHARED_KEY="$(python3 -c 'import os,base64;print(base64.b64encode(os.urandom(48)).decode())')"
MAA_MEASUREMENT="$(python3 -c 'import os;print(os.urandom(32).hex())')"
: > "$LOG"
echo "[s10] booting substrate ($ARM_PORT/$EGRESS_PORT/$AMQP_PORT/$EH_PORT, tls $TLS_PORT)..."
mix run --no-start --no-halt \
  -e "Application.put_env(:smalt, :sb_shared_key, \"$SB_SHARED_KEY\"); Application.put_env(:smalt, :maa_measurement_baseline, [\"$MAA_MEASUREMENT\"]); Application.put_env(:smalt, :arm_port, $ARM_PORT); Application.put_env(:smalt, :egress_port, $EGRESS_PORT); Application.put_env(:smalt, :amqp_port, $AMQP_PORT); Application.put_env(:smalt, :event_hubs_port, $EH_PORT); Application.put_env(:smalt, :arm_tls_port, $TLS_PORT); {:ok, _} = Application.ensure_all_started(:smalt)" \
  >>"$LOG" 2>&1 &
SUB_PID=$!
echo "$SUB_PID" > "$PID_FILE"

cleanup() {
  # Disarm first: this trap fires on EXIT/INT/TERM — re-entry (a TERM riding
  # the substrate teardown) must not restart teardown mid-way. set +e too:
  # the main body re-enables set -e after the court (line ~93), and a kill
  # on the already-dead substrate (control phase kills it first) would then
  # abort the trap mid-way and override the PASS exit 0 with 1.
  trap - EXIT INT TERM
  set +e
  kill "$SUB_PID" 2>/dev/null
  for _ in $(seq 1 25); do kill -0 "$SUB_PID" 2>/dev/null || break; sleep 0.2; done
  kill -9 "$SUB_PID" 2>/dev/null
  kill "$WATCHDOG_PID" 2>/dev/null
  rm -f "$PID_FILE"
  return 0
}
trap cleanup EXIT

# --- 4. poll until egress accepts ----------------------------------------------
up=0
for _ in $(seq 1 120); do
  if nc -z -w 1 127.0.0.1 "$EGRESS_PORT" 2>/dev/null; then up=1; break; fi
  kill -0 "$SUB_PID" 2>/dev/null || { echo "[s10] substrate died during boot; log: $LOG"; tail -20 "$LOG"; exit 2; }
  sleep 0.5
done
[ "$up" = 1 ] || { echo "[s10] substrate never came up; log: $LOG"; tail -30 "$LOG"; exit 2; }
echo "[s10] substrate up (pid $SUB_PID)"

# --- 5. watchdog --------------------------------------------------------------
( sleep "$WATCHDOG_SECS"; echo "[s10] WATCHDOG ${WATCHDOG_SECS}s expired"; kill -9 "$SUB_PID" 2>/dev/null; kill -9 $$ 2>/dev/null ) &
WATCHDOG_PID=$!

# --- 6. run the adversary court ------------------------------------------------
export MAA_MEASUREMENT SB_SHARED_KEY EGRESS_PORT ARM_PORT
set +e
python "$HERE/adversary.py"
PY_RC=$?
set -e
kill "$WATCHDOG_PID" 2>/dev/null || true

# --- 7. dead-substrate control: attest must now FAIL ----------------------------
kill "$SUB_PID" 2>/dev/null
for _ in $(seq 1 50); do
  nc -z -w 1 127.0.0.1 "$EGRESS_PORT" 2>/dev/null || break
  sleep 0.2
done
if nc -z -w 1 127.0.0.1 "$EGRESS_PORT" 2>/dev/null; then
  echo "[s10] substrate still holding $EGRESS_PORT after kill; control run inconclusive"
  exit 3
fi
echo "[s10] substrate down — dead-substrate control"
CTRL_OUT="$(EGRESS_PORT="$EGRESS_PORT" python - <<'PYCTRL'
import os, urllib.request, json
port = os.environ.get("EGRESS_PORT", "8443")
try:
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/attest/sevsnpvm",
        data=json.dumps({"measurement": os.environ["MAA_MEASUREMENT"]}).encode(),
        headers={"Content-Type": "application/json"},
    )
    urllib.request.urlopen(req, timeout=5)
    print("CONTROL-FAIL: attest succeeded with substrate down")
    raise SystemExit(1)
except Exception as exc:
    print(f"CONTROL-OK: attest refused with substrate down (port {port}): {type(exc).__name__}")
    raise SystemExit(0)
PYCTRL
)"
CTRL_RC=$?
echo "$CTRL_OUT"

echo "[s10] adversary suite exit: $PY_RC ; control exit: $CTRL_RC"
if [ "$PY_RC" = 0 ] && [ "$CTRL_RC" = 0 ]; then
  echo "[s10] COURT PASS"
  exit 0
fi
echo "[s10] COURT FAIL"
exit 1
