# 32-verification.just — verification governance gates + courts
# WO: docs/jira/v26.10.19 (verification governance lane): Non-Duplication
# Law gate for the residual test/internal tier + portable-target gate for
# verification/, with shim-court non-vacuity proofs for both.

smalt-root := justfile_directory()

# Non-Duplication Law gate over test/internal/**/*.{ex,exs} (fail-closed:
# honest red while the residual tier is empty/absent).
@non-duplication-gate:
    python3 {{smalt-root}}/scripts/non_duplication_gate.py

# Portable-target gate over verification/** (real Azure SDKs + stdlib only,
# documented env vars only; fail-closed on 0 files).
@portable-target-gate:
    python3 {{smalt-root}}/scripts/portable_target_gate.py

# Both verification gates, honest exit codes (aggregate stops on first red).
@verification-gates:
    python3 {{smalt-root}}/scripts/non_duplication_gate.py
    python3 {{smalt-root}}/scripts/portable_target_gate.py

# Shim courts: prove both gates are non-vacuous (clean PASS -> shim REFUSE).
@verification-courts:
    bash {{smalt-root}}/scripts/shim_court/non_duplication_gate_court.sh
    bash {{smalt-root}}/scripts/shim_court/portable_target_gate_court.sh
