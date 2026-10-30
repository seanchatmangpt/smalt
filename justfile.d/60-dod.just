# ============================================================================
# 60-dod.just — DoD single-source reader (dod.yaml + scripts/dod_check.py).
# Lane 1, v26.10.30 wave. Single disclosed addition of this lane; dod.yaml and
# the reader are lane-owned, this module only wires the entry points.
#
#   just dod                — run every gate in dod.yaml (exit 0 iff no FAIL
#                             among status:alive rows; SKIPs loud)
#   just dod-section s=...  — run only one section (e.g. s="coverage")
#
# Exit contract mirrors scripts/dod_check.py: 0 green / 1 honest FAIL.
# ============================================================================

# For an IMPORTED module justfile_directory() is already the repo root
# (witness: justfile.d/58-posh.just header).
DOD_ROOT := justfile_directory()

# dod — run the DoD gate ladder from dod.yaml end-to-end.
[no-cd]
dod:
    #!/usr/bin/env bash
    set -uo pipefail
    cd {{DOD_ROOT}}
    python3 scripts/dod_check.py --json-out tmp/posh/dod-latest.json

# dod-section — run only one section of dod.yaml.
[no-cd]
dod-section s:
    #!/usr/bin/env bash
    set -uo pipefail
    cd {{DOD_ROOT}}
    python3 scripts/dod_check.py --section "{{s}}" --json-out tmp/posh/dod-latest.json
