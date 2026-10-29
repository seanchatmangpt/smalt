#!/usr/bin/env bash
# run.sh — one-command runner for the saas-provisioning example.
# exit 0 pass / 1 fail / 2 substrate down / 3 loud skip.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

export SMALT_ARM="${SMALT_ARM:-http://127.0.0.1:9443}"
export SMALT_ARM_TLS="${SMALT_ARM_TLS:-https://localhost:9444}"
export SMALT_EGRESS="${SMALT_EGRESS:-http://127.0.0.1:8443}"
export NODE_EXTRA_CA_CERTS="$REPO/.smalt/tls/ca-cert.pem"

if [ ! -f "$NODE_EXTRA_CA_CERTS" ]; then
  echo "[ex8] SKIP: missing TLS CA at $NODE_EXTRA_CA_CERTS (run bash scripts/gen_dev_cert.sh)" >&2
  exit 3
fi

# SDK resolution from the verification tier's pinned @azure/* node_modules
export SMALT_SDK_ROOT="$REPO/verification/ts/node_modules"

node "$HERE/index.ts"
exit $?
