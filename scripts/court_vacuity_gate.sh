#!/usr/bin/env bash
# court_vacuity_gate.sh — Unified Chicago, Adversarial, Mutant, Court, and Vacuity Gate
# Validates non-vacuity and compliance across smalt and posh planes.
# Exit 0 = ALIVE (all courts pass, non-vacuous, zero mock leaks)
# Exit 1 = REFUSED / VACUOUS

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "========================================================================"
echo "  CROSS-PLANE ADVERSARIAL, MUTANT, CHICAGO, COURT & VACUITY GATE"
echo "========================================================================"

# Stage 1: Chicago School Mock-Free Audit Sweep
echo "[STAGE 1/5] Auditing Chicago Classicist Compliance (0 mock libraries)..."
python3 - << 'EOF'
import os, re, sys

banned_patterns = [
    r'\bMock\(',
    r'\bMagicMock\(',
    r'\btestify/mock\b',
    r'\bmock\.Mock\b',
    r'\bgomock\b',
    r'\bMox\b',
    r'\bHammox\b',
    r'\bMimic\b',
]

repo_root = os.environ.get("REPO_ROOT", ".")
violations = []
checked = 0

for root, _, files in os.walk(os.path.join(repo_root, "posh")):
    for f in files:
        if f.endswith("_test.go"):
            checked += 1
            path = os.path.join(root, f)
            with open(path, 'r', errors='ignore') as fp:
                for idx, line in enumerate(fp, 1):
                    for pat in banned_patterns:
                        if re.search(pat, line):
                            violations.append((path, idx, line.strip()))

for root, _, files in os.walk(os.path.join(repo_root, "test")):
    for f in files:
        if f.endswith(".exs") or f.endswith(".erl"):
            checked += 1
            path = os.path.join(root, f)
            with open(path, 'r', errors='ignore') as fp:
                for idx, line in enumerate(fp, 1):
                    if line.strip().startswith("#"):
                        continue
                    for pat in banned_patterns:
                        if re.search(pat, line):
                            violations.append((path, idx, line.strip()))

if violations:
    print(f"[FAIL] Found {len(violations)} mock violations in {checked} files:")
    for v in violations:
        print(f"  {v[0]}:{v[1]}: {v[2]}")
    sys.exit(1)

print(f"[PASS] {checked} test files verified: ZERO London-school mock libraries (Chicago Classicist).")
EOF

# Stage 2: POSH Mutation Court & Anti-Vacuity Gates
echo "[STAGE 2/5] Running POSH Admission Mutation Court..."
python3 "${REPO_ROOT}/scripts/posh_mutation_court.py"

# Stage 3: Sovereign Invariant Gate & Self-Check Mutations
echo "[STAGE 3/5] Verifying Sovereign Invariant Gate & Mutation Self-Checks..."
python3 "${REPO_ROOT}/scripts/must_not_migrate_gate.py"

# Stage 4: Zero-Proprietary Public Cloud Standards Ontology Court
echo "[STAGE 4/5] Running Public Cloud Standards Ontology Court..."
python3 "${REPO_ROOT}/scripts/verify_public_cloud_ontology.py"

# Stage 5: Chicago Loopback Platform Tests
echo "[STAGE 5/5] Running Full Chicago Platform Test Suite..."
cd "${REPO_ROOT}/posh" && go test -v -race ./tests/chicago/...

echo "========================================================================"
echo "  VERDICT: ALIVE [GREEN] (All 5 Adversarial & Anti-Vacuity Courts Passed)"
echo "========================================================================"
