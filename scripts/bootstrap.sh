#!/usr/bin/env bash
# smalt zero-to-green first-run bootstrap.
#
# Usage: bash scripts/bootstrap.sh   (relocates itself to the repo root)
#
# Exit 0 = green: prereqs, deps, compile, env check, certs, doctor, boot
#          smoke, and proof test all passed.
# Exit 1 = a stage failed; the [n/8] transcript names the exact stage.
# Exit 2 = missing prereq(s) (tools or a held port); the remediation is printed.
# Exit 124 = typed timeout (substrate never became ready within the poll budget).
#
# Idempotent: safe to rerun. `mix deps.get` is a no-op when deps are
# satisfied, `mix compile` is incremental, cert minting reuses existing
# material, and the boot smoke always tears down the substrate it started.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

STEP=0
T0=0
step() {
  STEP=$((STEP + 1))
  T0=$(date +%s)
  echo ""
  echo "[${STEP}/8] $1"
}
done_step() { echo "      ok ($(( $(date +%s) - T0 ))s)"; }

# ---------------------------------------------------------------------------
step "Prerequisites (elixir/mix/terraform/just/python3)"
MISSING=()
for bin in elixir mix terraform just python3; do
  command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: missing required tool(s): ${MISSING[*]}" >&2
  echo "Install with:" >&2
  echo "  brew install ${MISSING[*]}" >&2
  exit 2
fi
done_step

# ---------------------------------------------------------------------------
step "Hex dependencies (mix deps.get)"
mix deps.get
done_step

# ---------------------------------------------------------------------------
step "Compile (mix compile)"
mix compile
done_step

# ---------------------------------------------------------------------------
step "Dev environment check (scripts/dev_env.sh --check)"
bash scripts/dev_env.sh --check
done_step

# ---------------------------------------------------------------------------
step "TLS material (scripts/gen_dev_cert.sh)"
bash scripts/gen_dev_cert.sh
done_step

# ---------------------------------------------------------------------------
step "Doctor --fix (scripts/doctor.py)"
python3 scripts/doctor.py --fix
done_step

# ---------------------------------------------------------------------------
step "Boot smoke (substrate up -> GET /metadata/endpoints -> teardown)"
# If a substrate is ALREADY serving on 9443, reuse it for the smoke (idempotent
# rerun while `just up` is active) — never tear down a substrate we didn't
# start. Otherwise 9443/9545 must be free; a non-smalt holder fails fast with
# the holder named instead of burning the poll budget.
if curl -fsS -o /dev/null http://127.0.0.1:9443/metadata/endpoints 2>/dev/null; then
  ALREADY_UP=1
else
  ALREADY_UP=0
  for port in 9443 9545; do
    for _ in $(seq 1 30); do
      lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || break
      # Holder may be a substrate still booting — once it serves, reuse it.
      if [ "$port" = 9443 ] && \
         curl -fsS -o /dev/null http://127.0.0.1:9443/metadata/endpoints 2>/dev/null; then
        ALREADY_UP=1
        break
      fi
      sleep 2 # SLEEP-CLASS: POLL-STEP (bounded port-free poll, 30x2s deadline)
    done
    if [ "$ALREADY_UP" -ne 1 ] && lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "ERROR: port $port is held by a non-smalt-substrate process; smalt is single-substrate per host." >&2
      lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2
      echo "Stop the holder (just down / let the other tier finish) and rerun." >&2
      exit 2 # typed precondition: port must be free
    fi
    [ "$ALREADY_UP" -eq 1 ] && break
  done
fi
LOG="$(mktemp /tmp/smalt-bootstrap.XXXXXX.log)"
PID=""
cleanup() {
  # Kill the whole process group: `mix run` spawns a child beam; killing
  # only the mix parent orphans the beam, which keeps MCP port 9545 and
  # breaks the next bootstrap run with :eaddrinuse.
  # A reused (pre-existing) substrate is NEVER killed — we didn't start it.
  if [ -n "$PID" ]; then
    kill -- "-$PID" >/dev/null 2>&1 || kill "$PID" >/dev/null 2>&1 || true
    # Bounded reap poll on a real observable (kill -0); escalate to SIGKILL at
    # the deadline. No fixed coordination sleep.
    local i
    for i in $(seq 1 25); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.2 # SLEEP-CLASS: POLL-STEP (bounded reap poll)
    done
    if kill -0 "$PID" 2>/dev/null; then
      kill -9 -- "-$PID" >/dev/null 2>&1 || kill -9 "$PID" >/dev/null 2>&1 || true
    fi
    wait "$PID" 2>/dev/null || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

export SMALT_TLS_CERTFILE="$REPO/.smalt/tls/dev-cert.pem"
export SMALT_TLS_KEYFILE="$REPO/.smalt/tls/dev-key.pem"
export SSL_CERT_FILE="$REPO/.smalt/tls/ca-cert.pem"
set -m
if [ "$ALREADY_UP" -eq 0 ]; then
  # Spawn hygiene: stdin closed (substrate never reads it) + fd 9 closed so a
  # caller's flock is never inherited by the beam (lock-fd-inheritance law).
  mix run --no-halt >"$LOG" 2>&1 </dev/null 9>&- &
  PID=$!
fi
set +m

UP=0
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null http://127.0.0.1:9443/metadata/endpoints 2>/dev/null; then
    UP=1
    break
  fi
  sleep 1 # SLEEP-CLASS: POLL-STEP (bounded endpoint poll, 60x1s deadline)
done
if [ "$UP" -ne 1 ]; then
  echo "ERROR: substrate did not serve http://127.0.0.1:9443/metadata/endpoints within 60s" >&2
  echo "--- substrate log tail ($LOG) ---" >&2
  tail -30 "$LOG" >&2
  exit 124 # typed timeout (readiness poll exhausted)
fi
if [ "$ALREADY_UP" -eq 1 ]; then
  echo "      substrate already running — reused for smoke (not torn down)"
fi
echo "      GET http://127.0.0.1:9443/metadata/endpoints -> 200"
done_step

# ---------------------------------------------------------------------------
step "Proof test (mix test — fresh residual tier)"
mix test
done_step

echo ""
echo "GREEN: bootstrap complete. Start the substrate with: just up"
