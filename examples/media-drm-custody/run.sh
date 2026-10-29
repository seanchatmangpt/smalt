#!/usr/bin/env bash
# run.sh — one-command runner for the media-drm-custody example (ex6).
# exit 0 pass / 1 fail / 2 substrate down / 3 loud skip.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

export SMALT_TLS="${SMALT_TLS:-https://localhost:9444}"
export SMALT_ARM="${SMALT_ARM:-http://127.0.0.1:9443}"
export NODE_EXTRA_CA_CERTS="$REPO/.smalt/tls/ca-cert.pem"

if [ ! -f "$NODE_EXTRA_CA_CERTS" ]; then
  echo "[ex6] SKIP: missing TLS CA at $NODE_EXTRA_CA_CERTS (run bash scripts/gen_dev_cert.sh)" >&2
  exit 3
fi

# Loud substrate-down preflight (exit 2, typed) — KV TLS twin only.
sb_up() { bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }
if ! sb_up 9444; then
  echo "[ex6] SUBSTRATE-DOWN: KV TLS twin 9444 not listening. boot: scripts/substrate-ctl up --block front --auth enforce" >&2
  exit 2
fi

export SMALT_SDK_ROOT="$REPO/verification/ts/node_modules"

node "$HERE/index.ts"
exit $?
