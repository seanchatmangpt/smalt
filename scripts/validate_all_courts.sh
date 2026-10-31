#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

echo "========================================================================"
echo "  MASTER COURT RUNNER: VALIDATING PLAYWRIGHT VIDEO & ALL 4 PLANES"
echo "========================================================================"

echo "[STAGE 1/5] Verifying Generated Playwright E2E Video Artifact..."
VIDEO_PATH="/Users/sac/.gemini/antigravity-cli/brain/c4ea1bd1-2336-4778-8eea-e426e9f0a240/courtroom_walkthrough.mp4"
if [[ ! -f "${VIDEO_PATH}" ]]; then
  echo "[MASTER-FAIL] Video artifact missing at ${VIDEO_PATH}"
  exit 1
fi
echo "[STAGE 1/5] PASS: Video artifact exists ($(du -h "${VIDEO_PATH}" | awk '{print $1}'))"

echo "[STAGE 2/5] Running Chicago Cross-Plane Court (Next.js <-> Terraform <-> Go <-> Elixir)..."
bash "${REPO_ROOT}/scripts/cross_plane_court.sh"

echo "[STAGE 3/5] Running Kirkland & Ellis Compliance Court (IEEE OCEL 2.0 & pm4pytest)..."
bash "${REPO_ROOT}/scripts/kirkland_compliance_court.sh"

echo "[STAGE 4/5] Running POSH Admission & Anti-Vacuity Mutation Court (8 Gates)..."
python3 "${REPO_ROOT}/scripts/posh_mutation_court.py"

echo "[STAGE 5/5] Running Sovereign Invariant Gate (0 Leaks / P28-SIL)..."
python3 "${REPO_ROOT}/scripts/must_not_migrate_gate.py"

echo "========================================================================"
echo "  MASTER VERDICT: ALL COURTS & PLANES PROVEN ALIVE [GREEN]"
echo "========================================================================"
