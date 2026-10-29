#!/usr/bin/env bash
# ex5-insurance-governance runner — targets the shared substrate TLS twin.
# Exit contract: 0 pass / 1 fail / 2 substrate down / 3 loud skip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export NODE_EXTRA_CA_CERTS="$ROOT/.smalt/tls/ca-cert.pem"
export SMALT_ARM_TLS="${SMALT_ARM_TLS:-https://localhost:9444}"
cd "$ROOT/verification/ts"
exec node --experimental-strip-types "$ROOT/examples/insurance-governance/index.ts"
