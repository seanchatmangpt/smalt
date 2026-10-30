# 49 Registry Sweep: four-surface reconciliation (pin / KD register / coverage gate / gaps)

Lane 49, 2026-10-30. Sweep + reconcile of all four registration surfaces after the changed
facts: C1 (role_definition LIVE), C2 (KD-01 corrected semantics; KD-07/08/09 added),
C4 (raised api-version tops), ACR provider fix (2023-06-01 pin), G23 (KD-03 disjunctive
echo law), C8 (import assertions all 12).

## Surface 1 — server_test.go pin 12/7 vs actual registrations

- Pin: `server_test.go:87,127` (`expectedResources = 12`, `expectedDataSources = 7`).
- Actual: 11 `RegisterResource` call sites + 1 base (`NewResourceGroupResource`) = 12;
  6 `RegisterDataSource` call sites + 1 base (`NewClientConfigDataSource`) = 7.
- `go test ./... -run TestProviderResourcesAndDataSources -count=1` → ok (exit 0).
- Verified: C1 flipped `azurerm_role_definition` in place — no lane added a type; count 12/7
  unchanged.

## Surface 2 — posh/KNOWN_DIVERGENCES.md vs current reality

- KD-01: row's close condition ("roleDefinitions PUT/DELETE land on the face") is MET — face
  mounts GET/PUT/DELETE (`resource_providers.ex:4550-4566`; `lib/smalt/arm/rbac.ex`), provider
  does real CRUD (`resource_remaining_v1.go:1043-1260`). Row removed from active §5 table,
  moved to new §6 "Closed rows"; `resource:azurerm_role_definition` added to §4.1 PASS ledger.
- KD-03: already fixed by G23 (disjunctive echo law, dated 2026-10-30, gap lane 23) — verified
  in place, no edit needed.
- KD-02/04/05/06/07/08/09: re-checked against current code (honesty-law defaults, typed
  errors); still accurate as REGISTERED divergences.

## Surface 3 — coverage.py

- Before reconciliation: `8 registered / 12 pass / 0 missing / 20 cells; KD rows: 9`, exit 0.
- After: `7 registered / 13 pass / 0 missing / 20 cells; KD rows: 8`, exit 0. Self-test
  (bogus-op flip + restore) exit 0.

## Surface 4 — gaps/01 + INDEX.md

- gaps/01: "Updates (2026-10-30, registry-sweep lane 49)" appended — G1 CLOSED by C1,
  G7 superseded by C8, ACR `acrAPIVersion = 2023-06-01` noted.
- INDEX.md: addendum noting row 01's G1 closure and C8 import closure.

## Gate: scripts/posh_surface_crosscheck.sh (G20 --check-pin style)

New script `/Users/sac/smalt/scripts/posh_surface_crosscheck.sh` cross-checks pin consts vs
grepped registration counts (12/7 == 12/7), KD §2 prose counts vs pins (12/7 == 12/7), and
runs the coverage.py gate (0 missing). Exit 0 after reconciliation.

Non-vacuity (shim-court, real restore): KD §2 prose mutated 12→13 → crosscheck exit 1 with
`MISMATCH: KD prose resources 13 != pin 12`; file restored byte-exact
(sha256 `6b74174e…bef153954fa55a4c29b94ad71595a` before == after).

## Standing

ALIVE: four surfaces agree (pin == registrations == prose == coverage inventory), coverage
gate 0 missing exit 0, crosscheck exit 0, provider pin test green, import tests green.
Not covered: KD-09 (built-in role GUID mapping) remains open as REGISTERED; gaps/02
api-version-top rows belong to C4's receipts and were not re-audited here beyond the ACR pin.
