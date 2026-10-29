#!/usr/bin/env bash
# run.sh — ex2 retail-order-pipeline harness entry.
# Exit contract: 0 pass / 1 probe failure / 2 substrate down / 3 loud skip.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

# --- env contract (localhost defaults; override via SMALT_EX2_* / SMALT_SB_SHARED_KEY)
export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-$REPO/.smalt/tls/ca-cert.pem}"
export SMALT_EX2_TLS="${SMALT_EX2_TLS:-https://localhost:9444}"
export SMALT_EX2_AMQP_PORT="${SMALT_EX2_AMQP_PORT:-5672}"
export SMALT_EX2_EH_PORT="${SMALT_EX2_EH_PORT:-5673}"
# SAS shared key must match the substrate's deterministic per-host dev key
# (scripts/dev_env.sh formula); a hardcoded literal SAS-fails with
# INVALID_LOCAL_SAS.
export SMALT_SB_SHARED_KEY="${SMALT_SB_SHARED_KEY:-$(printf '%s' "$(hostname)smalt-dev-sb" | openssl dgst -sha256 -binary | base64)}"

# --- substrate-down preflight (exit 2, typed) ------------------------------
sb_up() { bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }
if ! sb_up 9443 || ! sb_up "$SMALT_EX2_AMQP_PORT" || ! sb_up "$SMALT_EX2_EH_PORT"; then
  echo "[ex2] SUBSTRATE-DOWN: required listeners (9443/${SMALT_EX2_AMQP_PORT}/${SMALT_EX2_EH_PORT}) not all up." >&2
  echo "[ex2] boot it with: just substrate-up" >&2
  exit 2
fi

# --- loud skip if SDKs are not installed -----------------------------------
if [ ! -d "$REPO/verification/ts/node_modules/@azure" ]; then
  echo "[ex2] LOUD-SKIP exit 3: @azure/* SDKs missing — run npm ci in verification/ts" >&2
  exit 3
fi

# node_modules symlink so ESM resolves @azure/* from verification/ts (lawful
# reuse of the suite's vendored SDKs; no second install).
if [ ! -e "$HERE/node_modules" ]; then
  ln -s ../../verification/ts/node_modules "$HERE/node_modules"
fi

node --no-warnings index.ts
