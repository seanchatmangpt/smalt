#!/usr/bin/env bash
# scripts/kirkland_compliance_court.sh — Automated Kirkland & Ellis Compliance Court
#
# Validates all 7 structural, mathematical, and compliance invariants:
# 1. Real sub-millisecond loopback execution (SLA < 500ms)
# 2. Fully connected multi-object process graph (Tenant -> Matter -> CRMH -> SIEM -> ContainerApp)
# 3. Cryptographic BLAKE3 turnstile continuity
# 4. Unified taxonomy across all layers
# 5. Strict IEEE OCEL 2.0 schema and referential integrity
# 6. Full combinatorial non-vacuous falsifiers (5 negative refusal events)
# 7. Standup specifics (CRMH blob naming regex, environment attribution, eval score 7)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_313="/opt/homebrew/opt/python@3.13/bin/python3.13"
PM4PYTEST_ROOT="/Users/sac/ggen-marketplace/packages/pm4pytest/src"
OCEL_LOG="/tmp/kirkland_compliance_audit.ocel.json"

echo "========================================================================"
echo "  KIRKLAND & ELLIS INFOSEC COMPLIANCE COURT (IEEE OCEL 2.0 & PM4PYTEST)"
echo "========================================================================"

# Stage 1: Execute Chicago Testbed Emission
echo "[STAGE 1/5] Running Chicago Loopback Test to Emit Compliant OCEL v2 Log..."
cd "${REPO_ROOT}/posh" && go test -v -race -run TestChicago_KirklandCompliance_OCELv2_Emission ./tests/chicago/

# Stage 2: Schema & Referential Integrity Verification
echo "[STAGE 2/5] Verifying Strict IEEE OCEL 2.0 Schema & Referential Integrity..."
python3 "${REPO_ROOT}/scripts/validate_ocel2.py" "$OCEL_LOG"

# Stage 3: Mathematical FSM Conformance via pm4pytest
echo "[STAGE 3/5] Evaluating Petri Net FSM Conformance (Fitness = 1.0 required)..."
PYTHONPATH="$PM4PYTEST_ROOT" "$PYTHON_313" -m pm4pytest.cli check-conformance \
  --log "$OCEL_LOG" \
  --fsm "tf.resource.provisioned,posh.turnstile.verified,crmh.export.completed,siem.audit.delivered" \
  --min-fitness 1.0 \
  --format tap

# Stage 4: Strict Temporal SLA Verification
echo "[STAGE 4/5] Evaluating Latency SLA (tf.resource.provisioned -> crmh.export.completed <= 500ms)..."
PYTHONPATH="$PM4PYTEST_ROOT" "$PYTHON_313" -m pm4pytest.cli check-sla \
  --log "$OCEL_LOG" \
  --sla "tf.resource.provisioned:crmh.export.completed:500.0" \
  --format tap

# Stage 5: Multi-Object Causal Graph OCPQ Traversal
echo "[STAGE 5/5] Evaluating Multi-Object OCPQ Traversal & Causal Invariants..."
PYTHONPATH="$PM4PYTEST_ROOT" "$PYTHON_313" -m pm4pytest.cli query \
  --log "$OCEL_LOG" \
  --traverse "Tenant,Matter,CRMHStorage,SIEMStream" \
  --require-activity "crmh.export.completed" \
  --format tap

PYTHONPATH="$PM4PYTEST_ROOT" "$PYTHON_313" -m pm4pytest.cli query \
  --log "$OCEL_LOG" \
  --traverse "Tenant,Matter,ContainerApp" \
  --require-activity "tf.resource.provisioned" \
  --format tap

echo "========================================================================"
echo "  VERDICT: ALIVE [GREEN] (All 7 Kirkland & Ellis Invariants Satisfied)"
echo "========================================================================"
