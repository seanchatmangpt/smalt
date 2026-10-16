# 09-verify-all — DoD lane module (owned by its lane; see docs/jira/v26.10.14)

# One-command verify-all: doctor, doctor-dod (if present), test-offline,
# workspace court, smalt-cli pytest, naming-sweep, invariant-gates.
# PASS/FAIL/SKIP verdict per stage, final table. Exit 0 only if no FAIL
# (SKIP allowed with reason). Offline stages only; no global substrate boot.
verify-all:
    @bash scripts/verify_all.sh
