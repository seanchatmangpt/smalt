#!/usr/bin/env bash
# cross_plane_court.sh — Cross-Plane Chicago Court
# Next.js <-> Terraform <-> Go POSH <-> Elixir BEAM
# A test only passes if it spans all 4 layers with ZERO mock doubles.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "========================================================================"
echo "  CROSS-PLANE CHICAGO COURT: NEXT.JS <-> TERRAFORM <-> GO <-> ELIXIR"
echo "========================================================================"

# Stage 1: Full-Stack Go Chicago Test (Next.js client simulation -> TF Provider -> POSH -> BEAM Store)
echo "[STAGE 1/3] Running Go Chicago Cross-Plane Court..."
cd "${REPO_ROOT}/posh" && go test -v -race -run TestChicago_FullStack_NextJSToTerraformToGoToElixir ./tests/chicago/...

# Stage 2: Unified IEEE OCEL 2.0 Conformance & pm4pytest Petri Net Verification
echo "[STAGE 2/3] Running IEEE OCEL 2.0 & pm4pytest Conformance Court..."
python3 "${REPO_ROOT}/scripts/ocel_pm4pytest_court.py"

# Stage 3: Sovereign BEAM Invariant Non-Regression Gate
echo "[STAGE 3/3] Verifying Sovereign Invariant Gate..."
python3 "${REPO_ROOT}/scripts/must_not_migrate_gate.py"

echo "========================================================================"
echo "  VERDICT: ALIVE [GREEN] (All 4 Layers Verified Without Chicago Gaps)"
echo "========================================================================"
