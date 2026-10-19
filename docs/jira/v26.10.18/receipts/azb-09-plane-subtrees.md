# Receipt: AZB-09 Plane-Scoped Supervision Subtrees

- **Ticket**: AZB-09
- **Subject**: `lib/smalt/plane/{control,data,integration,identity}_supervisor.ex`, `lib/smalt/application.ex`, `test/azsim/plane_supervision_test.exs`
- **Commit**: `a932816`
- **Status**: ALIVE

## Evidence
- `Supervisor.which_children(Smalt.Supervisor)` lists all four plane subtrees under `:all`.
- Terminating `Smalt.Plane.DataSupervisor` does not compromise `Smalt.Plane.ControlSupervisor` (ARM gateway), preserving blast radius containment without process poisoning.
- `mix test test/azsim/plane_supervision_test.exs`: 2 passed, 0 failures.
- `just sleep-gate`: PASS across 320 files (0 unclassified sleeps).
- `python3 scripts/isolation_court.py`: PASS across 160 modules (0 offenders).
