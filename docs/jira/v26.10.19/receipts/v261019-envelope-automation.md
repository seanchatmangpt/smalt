# Receipt: v26.10.19 envelope lane — automation-boundary gate + aggregate wiring

Standing: SUSPECT (skeleton — gate executed, receipts-embed law pending final embed)

- **Subject**: `scripts/envelope/automation_gate.py` +
  `justfile.d/35-envelope.just` (envelope lane; exclusive filename owner) +
  `docs/jira/v26.10.19/ENVELOPE_RESET.md`
- **Authority**: AZB-24 envelope WO (v26.10.19 window)
- **Executed**:
  - `python3 scripts/envelope/automation_gate.py` → exit 1:
    `[AUTOMATION-GATE] 29 violation(s) across 164 files — REFUSED`
    (classes: DEPRECATED-TEST-PATH, COORDINATION-SLEEP, UNMANAGED-SPAWN,
    HARDCODED-USER-PATH, SILENT-EXIT-0 — see ENVELOPE_RESET.md matrix)
  - `python3 scripts/envelope/automation_gate.py --self-test` → exit 0:
    `[SELF-TEST] PASS — all planted violations refused, clean fixtures pass`
- **Compile-freeze disclosure**: the container-gate lane overwrote
  `justfile.d/35-envelope.just` mid-task (a file this lane exclusively owns;
  siblings were told to report append lines). Merged, not reverted: their
  `@container-gate` / `@container-gate-self-test` recipes are preserved under
  the "Sibling-lane append" marker; their `envelope-root := justfile_directory()`
  root var resolved to `justfile.d/` (verified:
  `just -n container-gate` rendered `justfile.d/scripts/envelope/...`) and was
  corrected to the shared `ENVELOPE_ROOT`. Later converged by that lane to
  `ENVELOPE_ROOT := justfile_directory()` (correct for imported-module
  semantics; verified via simulated root import).
- **Verification (imported-context, simulated root import at repo root)**:
  all 9 recipes `just -n` OK; live exits: envelope-automation 1 (expected,
  29 open violations), envelope-container 1 (1 static REFUSE),
  envelope-iac 1 (1 violation), envelope-orchestration 1 (11 violations),
  leak-check 0, envelope-gates aggregate 1 (first-fail-wins),
  envelope-gates-courts typed 3 (reserved).
- **SUSPECT reason**: skeleton pending final embed of full raw gate output at
  wrap. Remaining open work: 29 automation violations, courts lane
  (`envelope-gates-courts`), import line in root Justfile (coordinator).
- **Import line for coordinator**: `import "justfile.d/35-envelope.just"`
