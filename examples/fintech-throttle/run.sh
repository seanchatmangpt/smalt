#!/usr/bin/env bash
# run.sh — ex7 fintech-throttle: boots its OWN private throttle substrate
# (block v6 = ports 39760-39765, enforce, arm_rate_limit=20) via the harness,
# then runs the probe. Exit contract: 0 pass / 1 fail / 2 substrate down /
# 3 loud skip.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
if [ ! -f "$REPO/.smalt/tls/ca-cert.pem" ]; then
  echo "[ex7] missing TLS CA at .smalt/tls/ca-cert.pem — run bash scripts/gen_dev_cert.sh" >&2
  exit 3
fi
export NODE_EXTRA_CA_CERTS="$REPO/.smalt/tls/ca-cert.pem"
exec node examples/fintech-throttle/index.ts
