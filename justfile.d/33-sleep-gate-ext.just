# 33-sleep-gate-ext — sleep-gate extension recipes (no-sleep doctrine gate).
#
# sleep_gate.py already scans verification/ (TS/PY suites, WARN-loud when
# absent; SLEEP_GATE_STRICT=1 promotes absence to failure). These recipes
# surface that surface as first-class gates.

# Scan the verification/ roots (TS + PY legs live in scripts/sleep_gate.py's
# default scope). SLEEP_GATE_STRICT=1 makes a missing verification/ dir a
# failure instead of a WARN — just sleep-gate-sdk strict=1
sleep-gate-sdk *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    if [ "{{flags}}" = "strict=1" ]; then
      export SLEEP_GATE_STRICT=1
    fi
    exec python3 scripts/sleep_gate.py

# TODO(loud): TS/PY shim-court legs do not exist yet. The existing court
# (scripts/shim_court/sleep_gate_court.sh) runs test/lib/burn/dual legs only —
# it exposes NO env flag to add TS/PY legs (legs are hardcoded bash fns), so
# this placeholder deliberately does NOT fake a pass. Typed refusal, exit 3,
# until the TS/PY legs land in the court and gain a flag (e.g. COURT_LEGS).
sleep-gate-sdk-court:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "[REFUSED exit 3] sleep-gate-sdk-court: TS/PY legs not yet in" \
         "scripts/shim_court/sleep_gate_court.sh (no leg env flag)." \
         "Run 'just sleep-gate-court' for the existing 4-leg court." >&2
    exit 3
