# GAP58 — Exit-code matrix (lane 5, 2026-10-30)

## Status: CLOSED (table landed + audit complete; 5 registered gaps)

Canonical table: `docs/jira/posh/v26.10.30/exit-codes.md`.

## What was audited

Every exit-emitting script/recipe in the posh fleet, exit patterns grepped in:
`scripts/posh_mutation_court.py`, `scripts/posh_sla.sh`,
`scripts/posh_coverage.py`, `scripts/posh_invariant_gate.py`,
`scripts/compat_pin_check.py`, `scripts/guard_local_apply.sh` (+ test),
`scripts/court_plane_discriminator.sh`, `scripts/egress_plane_discriminator.sh`,
`scripts/doctor_dod.py`, `scripts/doctor.py`, `posh/cmd/andon/main.go`,
`posh/cmd/posh/main.go` (runDoctor), `posh/internal/andon/`,
`adapters/terraform-provider-smalt/scripts/import_roundtrip_court.sh`,
`justfile.d/57-tf-provider.just`, `justfile.d/58-posh.just`,
`justfile.d/12-docs-dod.just`.

## Collisions found (see table's Collisions section)

1. exit 2 = SLA REFUSE / andon BLOCKED / guard usage / discriminator verdict —
   three meanings; typed `[TAG]` lines are the disambiguator (registered, not
   fixed — retyping across 6 scripts is not trivial).
2. exit 3 = SKIP (gate family) vs NONE/UNKNOWN (court discriminator).
3. exit 1 = FAIL everywhere except `egress_plane_discriminator.sh` where
   1 = DEFER VOID (a directive, not an audit failure).
4. `posh_invariant_gate.py` docstring omitted its own exit 3 — FIXED this
   commit (docstring only; code untouched, gate still flips to 1 via
   `just posh-invariant-court`).
5. `doctor_dod.py` WARN-exits-0 vs posh doctor `-strict` YELLOW-exits-1 —
   intentional, registered.

## Registered follow-ups (not fixed — non-trivial)

- exit 4 (TF-ARCHIVED) has no asserting test (archived tree, mix.exs gone).
- discriminator verdicts (0/2/3) have no automated court.
- compat/coverage/docs-dod-check/posh-doctor exit codes carry no dedicated
  exit-code assert.
- unifying 2/3 semantics across families would be a breaking change to every
  consumer that switches on the code; deferred with the typed-tag convention
  documented as the contract.

## Receipt

- Commands: grep sweeps over scripts/justfile.d/posh listed above; no
  production code changed except the one docstring.
- ALIVE: table published, audit complete, 1 trivial fix applied and
  disclosed, 4 items registered.
