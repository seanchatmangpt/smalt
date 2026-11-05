# 62-bin-opt.just — AoQ bin_opt_info match-context reuse gate + non-vacuity court
# (aq-architecture-spec §4, commit 25dd40df; lane L12r, v26.11.5)

BINOPT_ROOT := justfile_directory()

# Compile the AoQ surface with bin_opt_info; exit 0 only on zero scoped
# FAIL-class warnings (fail closed; exit 2 = loud refuse, never a fake pass).
@bin-opt:
    #!/bin/bash
    set -euo pipefail
    ROOT="{{BINOPT_ROOT}}"
    bash "$ROOT"/scripts/bin_opt_gate.sh

# Non-vacuity shim court: clean fixture PASSES the gate, an injected
# non-reusable binary match (SHIM-COURT) must flip it to exit 1.
@bin-opt-court:
    #!/bin/bash
    set -euo pipefail
    ROOT="{{BINOPT_ROOT}}"
    bash "$ROOT"/scripts/shim_court/bin_opt_court.sh
