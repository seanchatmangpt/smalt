# 12 — compat-pin split: CORE vs AZURERM-DIALECT

Source of truth: `/Users/sac/smalt/compat-pin.ttl` (landed G33/G45, 17 registryTop,
14 providerConstant, 1 registeredDivergence KD-45-1, surface 12/7, census 37,
5 payload laws). Current gate: `scripts/compat_pin_check.py`, wired as
`gate compat-pin scripts/compat_pin_check.py` in `scripts/posh_status.sh:121`
and non-vacuity-flipped by `just compat-court` (posh_help.sh:37).

Split law (from the migration contract): a row goes **CORE** iff it is
dialect-independent and owned by the smalt substrate; it goes **DIALECT** iff it
pins the azurerm-wire shape of a specific adapter package.

## Destination per row

### CORE pin → `compat-pin-core.ttl` (smalt repo root, substrate-owned)

| Pin row | Destination | Rationale |
|---|---|---|
| `smalt:aksClusterName "smalt"` | CORE | substrate-owned naming law (52-kind.just default) |
| `smalt:tfVersionFloor ">=1.14, <2.0"` + `tfFloorEvidence` | CORE | substrate deployment floor, dialect-independent |
| `smalt:resourceSurfaceCount 12` / `dataSourceSurfaceCount 7` | CORE | surface inventory of the substrate API itself (server_test.go inventory is the measurement, the counts are substrate contract) |
| payload laws `managedEnvironmentId-dual-key`, `memory-numeric-wire`, `location-always-set` | CORE | became core semantics per gaps/02 census (A8/A9-class laws: substrate renders azurerm-compatible wire; parity rows rated NONE/parity) — the substrate owns the wire law, the dialect merely consumes it |
| payload laws `tf-floor-gte-1.14`, `aks-cluster-name-smalt` | CORE | receipt/fence laws over substrate-owned config |
| `smalt:testCensusCount 37` | **DIALECT (moved)** | census counts `func Test` inside `internal/provider/*_test.go` — that is the dialect package's own test population, not a substrate fact |

### AZURERM-DIALECT pin → `adapters/terraform-provider-smalt/compat-pin.ttl`

| Pin row | Destination | Rationale |
|---|---|---|
| all 17 `smalt:registryTop` rows | DIALECT | per-type api-version ceilings are azurerm-wire facts |
| all 14 `smalt:providerConstant` rows | DIALECT | provider Go constants live in the dialect package |
| `registeredDivergence` `ficAPIVersion` (KD-45-1) | DIALECT | provider-vs-registry divergence is a dialect-package concern |
| `smalt:testCensusCount 37` | DIALECT | see above — provider test census |
| NEW `smalt:dialectBehavior "preview-normalization"` | DIALECT (add) | proposed row: pin the preview-field normalization behavior in the dialect shim |
| NEW `smalt:dialectBehavior "status-201-200-conventions"` | DIALECT (add) | proposed row: pin 201-on-create / 200-on-update ARM conventions the shim implements |

Note: two proposed `dialectBehavior` rows have no gate checker yet. They land
as REGISTERED-DIVERGENCE-class rows (documented, not checked) until a checker
exists — a pin row the gate cannot check is louder than a silent skip, but a
proposed unchecked row must not read as PASS.

## Gate-consumer changes

`scripts/compat_pin_check.py` splits into one binary, two pin loads:

- `--core-pin` (default `REPO/compat-pin-core.ttl`): checks cluster name, TF
  floor, surface 12/7, payload laws. Truth sources unchanged (registry.ex map
  shape, server_test.go blocks, provider source evidence greps, README, kind
  justfile).
- `--dialect-pin` (default `REPO/adapters/terraform-provider-smalt/compat-pin.ttl`):
  checks 17 tops, 14 constants, KD-45-1 divergence, census 37.
- No-arg invocation runs both and ORs the exit ladder (0/1/3 semantics
  preserved; a SKIP in either pin surfaces as 3).
- Census check moves to the dialect pass; the core pass drops
  `derive_census()`. `CHECKED_LAWS` stays in the core pass only.
- Path proposal: **core pin read from the smalt package root; dialect pin read
  from the dialect package** (`adapters/terraform-provider-smalt/`) — each pin
  travels with the artifact it pins, so a dialect consumer vendors the dialect
  pin by copying the adapter package, and the substrate pin by taking smalt.
- `scripts/posh_status.sh:121` gate line becomes two lines:
  `gate compat-pin-core scripts/compat_pin_check.py --core-pin` and
  `gate compat-pin-dialect scripts/compat_pin_check.py --dialect-pin`.

## Non-vacuity per split gate (`just compat-court`)

Each gate gets its own ACR mutation on a temp copy; a court that flips only one
of the two is vacuous for the other:

1. **core court**: mutate `compat-pin-core.ttl` temp copy — flip
   `resourceSurfaceCount 12 → 13`. Gate MUST exit 1.
2. **dialect court**: mutate the dialect pin temp copy — flip
   `acrAPIVersion 2023-06-01 → 2023-07-01` (existing ACR mutation, reused).
   Gate MUST exit 1.
3. **loud-skip probe**: run the gate with the dialect pin path pointing at a
   missing file — MUST exit 3 (COMPAT-PIN-SKIP), never 0.
4. All mutations on temp copies; sha256 restore check as in the current court.

Fallback order if (2) cannot flip: mutate a registryTop row instead; if still
no flip, the split is FAIL (the dialect pass is not checking the rows it
claims).

## Status

**ALIVE** — split executed 2026-10-30 (M12 gap lane, v26.10.31 wave).

- `compat-pin-core.ttl` (repo root) + `adapters/terraform-provider-smalt/compat-pin.ttl`
  carry the 33 rows per the tables above (no row re-adjudicated);
  the monolith `compat-pin.ttl` is retired.
- `scripts/compat_pin_check.py` is one binary, two pin loads
  (`--core-pin` / `--dialect-pin`, ORed exit ladder 0/1/3; census moved to
  the dialect pass; `CHECKED_LAWS` core-only; flag-only invocation runs its
  own pass — matches the two-line posh_status wiring).
- `scripts/posh_status.sh` gates split into `compat-pin-core` /
  `compat-pin-dialect`; `just compat-court` (justfile.d/58-posh.just) runs
  both mutation legs + the missing-pin loud-skip probe, sha256 restore on
  both pins.
- Court witness: core leg exit 1 on surfaceCount 13 mutation; dialect leg
  exit 1 on acr mutation; loud-skip exit 3 on missing dialect pin; court
  exit 0. Contract falsifier witnessed: removing a CORE row
  (`resourceSurfaceCount`) from a temp copy of the core pin → gate exit 3
  COMPAT-PIN-SKIP, never a silent pass.
- `ggen sync run` NOT rerun: no pack shape changed (pins are not pack
  shapes; the dialect pin travels with `adapters/`, outside the pack).
