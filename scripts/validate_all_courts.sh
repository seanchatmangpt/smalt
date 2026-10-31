#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

echo "========================================================================"
echo "  MASTER COURT RUNNER: VALIDATING ALL SOVEREIGN PLANES & GATES"
echo "========================================================================"

echo "[STAGE 1/4] Running Chicago Cross-Plane Court (Client <-> Terraform <-> Go <-> Elixir)..."
bash "${REPO_ROOT}/scripts/cross_plane_court.sh"

echo "[STAGE 2/4] Running Enterprise Multi-Tenant Compliance Court (IEEE OCEL 2.0 & pm4pytest)..."
bash "${REPO_ROOT}/scripts/enterprise_compliance_court.sh"

echo "[STAGE 3/4] Running POSH Admission & Anti-Vacuity Mutation Court (8 Gates)..."
python3 "${REPO_ROOT}/scripts/posh_mutation_court.py"

echo "[STAGE 4/4] Running Sovereign Invariant Gate (0 Leaks / P28-SIL)..."
python3 "${REPO_ROOT}/scripts/must_not_migrate_gate.py"

echo "========================================================================"
echo "  MASTER VERDICT: ALL COURTS & PLANES PROVEN ALIVE [GREEN]"
echo "========================================================================"
