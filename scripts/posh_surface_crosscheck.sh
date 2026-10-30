#!/usr/bin/env bash
# posh_surface_crosscheck.sh — G20 --check-pin style cross-check (lane 49, 2026-10-30).
# Cross-checks the posh/terraform-provider registration surfaces:
#   1. server_test.go pin consts (expectedResources / expectedDataSources)
#      vs actual registrations (RegisterResource/RegisterDataSource call sites + base).
#   2. KD register §2 prose counts ("12 required sovereign resources and 7 data sources")
#      vs the pins (the silent prose-drift edge from gaps/20).
#   3. coverage.py gate (0 missing cells; every cell PASS or KD-registered).
# Any mismatch exits 1. Zero-arg, read-only over the repo tree.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN_FILE="$REPO/adapters/terraform-provider-smalt/internal/provider/server_test.go"
KD_FILE="$REPO/posh/KNOWN_DIVERGENCES.md"
COVERAGE="$REPO/posh/scripts/coverage.py"
fail=0

pin_r=$(grep -E 'const expectedResources' "$PIN_FILE" | grep -oE '[0-9]+')
pin_d=$(grep -E 'const expectedDataSources' "$PIN_FILE" | grep -oE '[0-9]+')
reg_r=$(( $(grep -RhoE '^\s*RegisterResource\(' "$REPO/adapters/terraform-provider-smalt/internal/provider" --include='*.go' \
           | grep -v server.go | wc -l | tr -d ' ') + 1 ))  # +1 base NewResourceGroupResource
reg_d=$(( $(grep -RhoE '^\s*RegisterDataSource\(' "$REPO/adapters/terraform-provider-smalt/internal/provider" --include='*.go' \
           | grep -v server.go | wc -l | tr -d ' ') + 1 ))  # +1 base NewClientConfigDataSource

echo "pin resources=$pin_r datasources=$pin_d | registrations resources=$reg_r datasources=$reg_d"
[ "$pin_r" = "$reg_r" ] || { echo "MISMATCH: resource pin $pin_r != registrations $reg_r"; fail=1; }
[ "$pin_d" = "$reg_d" ] || { echo "MISMATCH: datasource pin $pin_d != registrations $reg_d"; fail=1; }

prose=$(grep -oE 'the [0-9]+ required sovereign resources and [0-9]+ data sources' "$KD_FILE" | head -1)
prose_r=$(echo "$prose" | grep -oE '[0-9]+' | sed -n 1p)
prose_d=$(echo "$prose" | grep -oE '[0-9]+' | sed -n 2p)
echo "KD §2 prose counts: resources=$prose_r datasources=$prose_d"
[ "$prose_r" = "$pin_r" ] || { echo "MISMATCH: KD prose resources $prose_r != pin $pin_r"; fail=1; }
[ "$prose_d" = "$pin_d" ] || { echo "MISMATCH: KD prose datasources $prose_d != pin $pin_d"; fail=1; }

echo "--- coverage.py gate"
if ! python3 "$COVERAGE" >/dev/null; then
  echo "MISMATCH: coverage.py gate exited nonzero (missing cells)"
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "CROSSCHECK OK"
else
  echo "CROSSCHECK FAIL — mismatch rows above name the divergent count; fix the pin/KD prose, never posh_coverage.py output"
fi
exit "$fail"
