# Receipt: Lane C2 — honesty-law gap close (G2/G3/G5/G6)

Subject: `adapters/terraform-provider-smalt` @ main, 2026-10-30 (uncommitted working tree).
Closes GAP1 rows G2, G3, G5, G6 (DEGRADED → closed as loud-by-default) in
`docs/jira/posh/v26.10.30/gaps/01-provider-azurerm-parity.md`.

## Diff (files)

- `internal/provider/resource_remaining_v1.go` — honesty-law helpers
  (`allowFabricatedIDs`, `refuseFabricatedValue`, `fabricatedValueWarning`);
  `carryOrMintIdentityAttr` error-by-default; FIC create/update/delete/read and
  role_assignment create/read/delete unsupported-route swallows → typed errors;
  `resolveRoleDefinitionInput` bare-name mint warning + nil-safe diags;
  `role_definition_name` schema Description fabrication notice.
- `internal/provider/data_sources_v1.go` — UAI data source silent mint → error-by-default.
- `internal/provider/resource_container_app_environment.go` — `default_domain`
  fabricated fallback → error-by-default (attr null on refusal).
- `internal/provider/honesty_law_test.go` — new court (both env branches, flips).
- `internal/provider/live_test.go` — `resolveRoleDefinitionInput` 4th arg (nil).
- `posh/KNOWN_DIVERGENCES.md` — KD-01/KD-02 updated; KD-07/KD-08/KD-09 added.

## Gates (actual exits)

- `go vet ./...` → exit 0
- `go test ./... -race` → exit 0 (provider package ok)
- `TFPOSHT_LIVE=1 go test -run Live -v` → all PASS incl.
  `TestLiveRoleAssignmentRoundtrip` with the new mint warning witnessed in the log
  (Reader → 081cfaa7-56df-51ed-82ef-d08f7f66afb5).

## Silent→loud flips

1. UAI data source `client_id`/`principal_id` mint: silent → error (warn+mint under env).
2. UAI resource mint (no prior state): warn-only → error (warn+mint under env).
3. CAE `default_domain` fabricated fallback: silent → error.
4. FIC create/update/delete/read unsupported-route success: silent → error.
5. role_assignment create/read/delete unsupported-route success: silent → error.
6. role_assignment bare `role_definition_name` uuid5 mint: silent → warning on every
   resolution + schema Description notice (KD-09; error would block consumer until C1).

Not flipped: `role_assignment.name` GUID mint when omitted (matches Azure's own
server-generated GUID name semantics; registered under KD-08's surface only where
routes are unsupported), ACR/LAW/storage key mints (G11/G13 COSMETIC, out of lane scope).

## Standing

ALIVE for the provider package gates above, executed this session. Real-plane behavior
of `TFPOSH_ALLOW_FABRICATED_IDS=1` through full terraform-plan/apply was not executed
(unit courts + live roundtrips only). Pre-existing: `gofmt -l` flags
`resource_container_app.go` (unmodified by this lane).
