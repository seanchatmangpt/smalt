# 05-doctor-ext — DoD-5 lane module (owner: DoD-5; see docs/jira/v26.10.14)
#
# Supplemental Definition-of-Done check pass alongside the pinned fail-closed
# court scripts/doctor.py (never edited by this lane). Non-fatal INFO/WARN
# lines; hard FAIL only on the DoD conditions encoded in the script.
# Exit 0 unless a FAIL fires.

DOD5_ROOT := justfile_directory()

# Supplemental DoD doctor pass (INFO/WARN + FAIL on DoD violations)
doctor-dod:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{DOD5_ROOT}}"
    python3 scripts/doctor_dod.py
