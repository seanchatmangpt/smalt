# 61-tripwire.just — GAP-17 must-not-migrate tripwire gate
#
# Normative source: docs/jira/posh/v26.10.31/gaps/17-what-must-not-migrate.md
# (the Forbidden List). Gate: scripts/must_not_migrate_gate.py — F1 GraphLaw
# admission homes, F2 turnstile/settlement/event-log seam, F2b pinned BLAKE3
# kernel byte-identity. Fail-closed; non-vacuity via /tmp scratch-copy
# self-check (repo never mutated). Exit 0 pass / 1 violation or vacuous /
# 3 loud skip.

TRIPWIRE_ROOT := parent_directory(justfile_directory())

# Full gate: live-tree scan + non-vacuity self-check (default).
@tripwire-gate:
    cd {{TRIPWIRE_ROOT}} && python3 scripts/must_not_migrate_gate.py

# Non-vacuity proof only (shim-court falsifier on /tmp scratch copies).
@tripwire-self-check:
    cd {{TRIPWIRE_ROOT}} && python3 scripts/must_not_migrate_gate.py --self-check-only

# Scan only (no self-check) — local iteration; not a gate verdict.
@tripwire-scan:
    cd {{TRIPWIRE_ROOT}} && python3 scripts/must_not_migrate_gate.py --skip-self-check
