# 65-ports — port-law mechanical gate (HR-I lane, v26.11.6).
# Authority: docs/reference/port_law.md; gate: scripts/port_registry_check.py
# (--falsify self-test corpus + fail-closed live census; exit 0/1/2).
port-law:
    #!/usr/bin/env bash
    set -uo pipefail
    cd "$(git rev-parse --show-toplevel)"
    python3 scripts/port_registry_check.py --falsify || exit 1
    python3 scripts/port_registry_check.py --check
