#!/usr/bin/env bash
# Build the trust shim probe. darwin-only (cgo Security.framework).
# Output: scripts/trust_shim_probe/trust_shim_probe (local convenience
# binary; the tf_* scripts build their own mktemp binary via `go build`).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
go build -o trust_shim_probe .
echo "built: $DIR/trust_shim_probe"
