# 35-envelope.just — AZB-24 envelope reset: four-layer gate aggregate (Phase 0).
# Owner: envelope lane (exclusive filename owner per _LANES.md). Sibling gate
# lanes land their gate scripts under scripts/envelope/ and report append lines;
# this module carries every envelope recipe. Aggregate is first-fail-wins (just
# stops at the first failing prerequisite). Missing gate scripts are a typed
# SKIP (exit 3), never a silent pass.
#
# ROOT law (measured 2026-10-19): inside an IMPORTED module,
# `justfile_directory()` returns the ROOT justfile's dir (/Users/sac/smalt),
# NOT the module's own dir — so no parent_directory() needed here. (The
# fanout rule-5 shebang caveat applies to standalone justfiles; `just -d`
# style. Verified live: parent_directory() here resolves to /Users/sac.)
ENVELOPE_ROOT := justfile_directory()

# Phase 0 gate 1/4 — Automation Boundary (LANDED: scripts/envelope/automation_gate.py)
envelope-automation:
    python3 {{ENVELOPE_ROOT}}/scripts/envelope/automation_gate.py

# Phase 0 gate 2/4 — Hermetic/Container boundary
# (scripts/envelope/container_gate.py landing this window; typed SKIP until then)
envelope-container:
    #!/bin/bash
    set -u
    if [ -f "{{ENVELOPE_ROOT}}/scripts/envelope/container_gate.py" ]; then
        exec python3 "{{ENVELOPE_ROOT}}/scripts/envelope/container_gate.py"
    fi
    echo "[ENVELOPE-CONTAINER] SKIP (typed 3) — container_gate.py not landed (PENDING)"
    exit 3

# Phase 0 gate 3/4 — IaC boundary
envelope-iac:
    #!/bin/bash
    set -u
    if [ -f "{{ENVELOPE_ROOT}}/scripts/envelope/iac_gate.py" ]; then
        exec python3 "{{ENVELOPE_ROOT}}/scripts/envelope/iac_gate.py"
    fi
    echo "[ENVELOPE-IAC] SKIP (typed 3) — iac_gate.py not landed (PENDING)"
    exit 3

# Phase 0 gate 4/4 — Orchestration boundary
envelope-orchestration:
    #!/bin/bash
    set -u
    if [ -f "{{ENVELOPE_ROOT}}/scripts/envelope/orchestration_gate.py" ]; then
        exec python3 "{{ENVELOPE_ROOT}}/scripts/envelope/orchestration_gate.py"
    fi
    echo "[ENVELOPE-ORCHESTRATION] SKIP (typed 3) — orchestration_gate.py not landed (PENDING)"
    exit 3

# Aggregate: all four layer gates, first-fail-wins.
envelope-gates: envelope-automation envelope-container envelope-iac envelope-orchestration
    @echo "[ENVELOPE] aggregate complete (exit reflects first failure, if any)"

# Reserved: shim courts for the envelope gates. Typed exit 3 until they land.
envelope-gates-courts:
    #!/bin/bash
    echo "[ENVELOPE-COURTS] RESERVED — no envelope shim courts exist yet"
    echo "[ENVELOPE-COURTS] (automation/container/iac/orchestration non-vacuity) — typed 3"
    exit 3

# Leak check: scripts/leak_detector.sh if landed, else a typed note.
leak-check:
    #!/bin/bash
    set -u
    if [ -f "{{ENVELOPE_ROOT}}/scripts/leak_detector.sh" ]; then
        exec bash "{{ENVELOPE_ROOT}}/scripts/leak_detector.sh"
    fi
    echo "[LEAK-CHECK] SKIP (typed 3) — scripts/leak_detector.sh not landed (PENDING)"
    exit 3

# --- Sibling-lane append (container-gate lane; root var corrected to ROOT,
# --- disclosed in v261019-envelope-automation.md receipt) -------------------

# Container gate: static Dockerfile.hermetic analysis + optional runtime
# docker history/inspect when the daemon and a hermetic image exist.
# Fail-closed exit 0/1. --self-test refuses 8 poisoned inline fixtures.
@container-gate:
    python3 {{ENVELOPE_ROOT}}/scripts/envelope/container_gate.py

@container-gate-self-test:
    python3 {{ENVELOPE_ROOT}}/scripts/envelope/container_gate.py --self-test
