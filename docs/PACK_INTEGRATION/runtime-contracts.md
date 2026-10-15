# Runtime Integration Contracts — Pack Integration Receipt

Lane: runtime contracts. Repo: ~/smalt. Date: 2026-10-14.
Owned files: `lib/smalt/runtime_contracts/` (new), `test/runtime_contracts_test.exs` (new), `docs/PACK_INTEGRATION/runtime-contracts.md` (this file). No git operations.

## What was built

Machine-checkable runtime integration contracts binding smalt's planes to their consumers. One contract module per plane, executable as fast in-process checks (`Plug.Test.conn` dispatch of the real routers — no sockets, no Bandit, no ports).

| contract | plane | consumer |
|---|---|---|
| `Smalt.RuntimeContracts.ArmEnvelope` | control_plane | `Smalt.ArmGateway.Router` |
| `Smalt.RuntimeContracts.CosmosHeader` | data_plane | `Smalt.EgressRouter` (/dbs surface) |
| `Smalt.RuntimeContracts.AmqpDialect` | messaging_plane | `Smalt.Amqp.FrameCodec` + `Smalt.Amqp.DeliveryEncoder` |

### Invariants fenced (pinned by the compliance courts)

`ArmEnvelope` (from `test/compliance/c1_arm.exs` / `docs/compliance/C1_ARM_REST.md`):
error envelope (`error.code`/`error.message`, `application/json; charset=utf-8`), GraphLaw refusal envelope (400 `InvalidResourceShape`, target `AshGraphLaw.Enforcement`), catch-all 404 `RouteNotFound`, success envelope (id/name/type/location/`properties.provisioningState`), PUT create 201 / update 200 / DELETE 200 / GET-after-delete 404, LRO 202 + Azure-AsyncOperation/Location/Retry-After: 1 + `status: InProgress` + poll-to-terminal 200, api-version gate (400 `MissingApiVersionParameter` / `InvalidApiVersionParameter`), LIST `{"value": [...]}` including the created resource.

`CosmosHeader` (from `test/compliance/c3_cosmos.exs` — spelling fix on landing: `c3_cosmos.exs`):
required header set on success AND 404 (`x-ms-request-charge`, `x-ms-session-token`, `x-ms-lsn`, `x-ms-alt-content-path` + container-path echo, token shape `^\d+#\d+$`, lsn >= 0), `_etag` quoted 64-hex, stable on read, refreshed on write (header equals body `_etag`), system properties (`_rid`, `_self` path grammar, `_ts` integer), status semantics (201 create / 200 replace / 204 conditional delete via If-Match / 404 second delete), pk-header semantics (missing / non-array / mismatched -> 400 `BadRequest`), `application/query+json` feed `{_rid, Documents, _count}` with partition filter respected, DatabaseAccount envelope (kind + writableLocations).

`AmqpDialect` (from `test/amqp/*`): 8-byte frame header (size::32 = frame byte size, doff = 2, channel::16 round-trip), performative round-trips (open/begin/attach/close/end, transfer + raw payload), SASL ANONYMOUS mechanisms round-trip, message-section round-trips (header/properties/annotations/DLQ footer, annotation maps carried directly not 1-element lists), body_data as vbin (0x100 random bytes survives byte-exact), Service Bus filetime lock dialect `(ms + 11_644_473_600_000) * 10_000` and `com.microsoft:locked-until-utc` annotation surviving wire round-trip, encoder section shape (`header.delivery_count`, `x-opt-sequence-number`, DLQ footer in application_properties).

## Pack usage and adaptation disclosure

- Source packs: `~/ggen-marketplace/packs/ash-runtime-integration-contract-pack` (contract-module shape: `templates/api_contract.ex.tmpl`, consumer-binding metadata columns) and `~/ggen-marketplace-packs` typo guard — actual path `…/ash-revops-structural-factory-pack` (revops structural factory pass: verdict fan-out over every wired contract, injectable list for mutation courts).
- ggen projection: `lib/smalt/runtime_contracts/ggen/` holds a consumer `ggen.toml` + `ontology.ttl` + query + template. `ggen sync run` (ggen 26.10.11) deterministically projects three generated catalog modules into `lib/smalt/runtime_contracts/generated/` (one per contract: id, plane, consumer, source pack, label, module). ggen renders per query row (an aggregate `rows` variable is not part of the template context — disclosed adaptation), and ggen's write guard refuses `../` output paths, so the replay step is: run `ggen sync run` in `ggen/`, then `cp generated/*.ex ../generated/`.
- The hand-written contract modules fence the invariants; the generated catalog modules pin the plane↔module binding so wiring cannot drift from the declared graph. Coherence is tested.

## Verify surface

- `Smalt.RuntimeContracts.verify/0` — revops structural factory pass: fans `check/0` over every wired contract (behaviour `Smalt.RuntimeContracts.Contract`), returns one verdict map `%{pass, contracts, planes, contract_count, check_count, failure_count}`.
- `Smalt.RuntimeContracts.verify/1` — injection point: mutation courts pass a broken test-copy contract and the verdict must fail with the pinned check id (tested: `arm_envelope_broken` / `injected_break_catch_all_404`).
- `verify/1` with an empty list fails closed (no contracts => no pass).

## Gate

`mix test test/runtime_contracts_test.exs` — GREEN: `5 tests, 0 failures` (two consecutive confirmed runs, 2026-10-15 ~05:55–06:03 UTC; ggen `sync run --dry-run` after the runs reports generated content unchanged = deterministic projection). The remaining compile warnings in the suite output are all from other lanes' in-flight files, none from `lib/smalt/runtime_contracts/`. Known environmental flake (pre-existing, not this lane): the shared-checkout port race on the app-start listeners (`:eaddrinuse` when concurrent lanes' suites boot simultaneously); config/test.exs's free-port probing narrows but does not eliminate it — retry passes.
