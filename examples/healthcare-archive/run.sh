#!/bin/bash
# run.sh — Healthcare compliance archive example (lane ex3).
# Exits: 0 pass / 1 check FAIL / 2 substrate down / 3 loud skip.
# Substrate: reuses a healthy shared substrate when present; otherwise boots
# a lane-private one on v-block v6 via scripts/substrate-ctl (flock-managed,
# lane-safe) and sweeps it down after.
set -u
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"
CTL="$REPO/scripts/substrate-ctl"
BLOCK="${EX3_BLOCK:-v6}"
OWN_SUB=0

# Bare-specifier resolution for @azure/* — symlink the vendored SDKs in
# (inside this lane's dir; never touching verification/).
if [ ! -e node_modules ]; then
  ln -s ../../verification/ts/node_modules node_modules
fi

health() {
  curl -s -o /dev/null -m 4 -w "%{http_code}" "${SMALT_ARM_HTTP:-http://127.0.0.1:9443}/metadata/endpoints" 2>/dev/null
}

if [ "$(health)" != "200" ]; then
  OWN_SUB=1
  OUT="$(mktemp)"
  if ! "$CTL" up --block "$BLOCK" --auth enforce >"$OUT" 2>&1; then
    echo "LOUD-SKIP exit 2: shared substrate down and substrate-ctl up failed:" >&2
    tail -5 "$OUT" >&2
    exit 2
  fi
  R="$(tail -1 "$OUT")"
  PORTS="$(node -e "console.log(JSON.parse(process.argv[1]).ports.join(' '))" "$R")"
  set -- $PORTS # amqp eh arm egress tls mcp
  export SMALT_ARM_HTTP="http://127.0.0.1:$3"
  export SMALT_EGRESS="http://127.0.0.1:$4"
  export SMALT_TLS="https://localhost:$5"
  echo "[run.sh] lane-private substrate block=$BLOCK pid=$(node -e "console.log(JSON.parse(process.argv[1]).pid)" "$R") ports=$PORTS"
fi

export NODE_EXTRA_CA_CERTS="$REPO/.smalt/tls/ca-cert.pem"
export SMALT_REPO="$REPO"
export SMALT_ARM="${SMALT_ARM:-https://127.0.0.1:9444}"
export SMALT_EGRESS="${SMALT_EGRESS:-http://127.0.0.1:8443}"
export SMALT_TLS="${SMALT_TLS:-https://127.0.0.1:9444}"

node index.ts
CODE=$?

if [ "$OWN_SUB" = "1" ]; then
  "$CTL" down --block "$BLOCK" --mode sweep >/dev/null 2>&1
fi
exit $CODE
