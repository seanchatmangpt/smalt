# POSH-010: implementation wave plan (fan-out contract)

## Task
Fan-out onto the ONE canonical smalt checkout (no worktrees), lanes:
L1 scaffold+membane (POSH-001/002 Go side), L2 ARM face (POSH-003),
L3 provider (POSH-004), L4 packaging (POSH-005), L5 courts (POSH-006),
L6 parity register (POSH-009), L7 fences (POSH-008), L8 migration ledger (POSH-007).
Seams: posh/internal/api/types.go is the shared seam — owned by L1, changes via
RESOLUTIONS.md note. Coordinator owns git transitions; per-lane build roots.

## Acceptance
Wave-1 read-only (each lane files an edit plan against the seams), resolve, then
write. Integration: verify ladder + per-lane atomic commits + lane root cleanup
(leases deleted before final commit).

## Falsifier
Any defect caught by coordinator pre-thinking instead of a court marks the wave
decoration (fanout-first law).
