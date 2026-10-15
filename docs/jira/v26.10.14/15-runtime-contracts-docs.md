# V261014-15 — Runtime Contracts: documentation drift remediation (docs-only)

- **Release:** v26.10.14 · **Scope:** tiny — docs-only, no behavior change
- **Owned files:** `lib/smalt/runtime_contracts.ex` (moduledoc only), `docs/PACK_INTEGRATION/runtime-contracts.md`
- **Precondition:** lane is code-green — 28 tests, 0 failures (verified twice; generated catalog + MANIFEST.sha256 + b3sum fence agree). **The code is self-consistent and court-pinned; the docs move, never the code.**

## 1. Background

The lane wired **six** contract modules (`@wired` at `runtime_contracts.ex:34`: ArmEnvelope, CosmosHeader, AmqpDialect, SentinelIngest, ResourceGraphQuery, PurviewAtlas), but both prose surfaces still describe the original three. The pack-receipt doc also carries a stale gate witness and a wrong filetime epoch constant.

## 2. Change 1 — moduledoc contract list (`runtime_contracts.ex:8-10`)

Replace the 3-bullet list with six entries (order matches `@wired` at :34):

```
* Smalt.RuntimeContracts.ArmEnvelope — control plane, ARM envelope
* Smalt.RuntimeContracts.CosmosHeader — data plane, Cosmos header set
* Smalt.RuntimeContracts.AmqpDialect — messaging plane, AMQP 1.0 dialect
* Smalt.RuntimeContracts.SentinelIngest — data plane, Sentinel / Log Analytics DCR ingest + KQL query
* Smalt.RuntimeContracts.ResourceGraphQuery — control plane, Resource Graph query + $skipToken pagination
* Smalt.RuntimeContracts.PurviewAtlas — data plane, Purview Catalog (Atlas v2) entities + lineage
```

(Plane assignments verified from each module's `plane/0`.) Do not touch anything below the moduledoc.

## 3. Change 2 — pack receipt table, gate witness, filetime constant (`runtime-contracts.md`)

### 3a. Contract table (:11-15)

Add 3 rows so the table reads 6 total:

| contract | plane | consumer |
|---|---|---|
| `Smalt.RuntimeContracts.SentinelIngest` | data_plane | `Smalt.EgressRouter` (Sentinel surface) |
| `Smalt.RuntimeContracts.ResourceGraphQuery` | control_plane | `Smalt.EgressRouter` (Resource Graph surface, backed by `Smalt.DataPlane.ResourceGraph`) |
| `Smalt.RuntimeContracts.PurviewAtlas` | data_plane | `Smalt.EgressRouter` (Atlas surface, backed by `Smalt.DataPlane.Purview`) |

(Verify the exact `Smalt.DataPlane.*` module names against `lib/smalt/data_plane/` at edit time.)

### 3b. Gate witness (:40)

Replace "5 tests, 0 failures" with "28 tests, 0 failures"; keep the rest of the sentence (two-run witness, `sync run --dry-run` determinism note, port-race flake note). This doc is a receipt — update in place, cite the lane's verified twice-green 28/0 status.

### 3c. Filetime constant (:24)

Doc says `(ms + 11_644_473_600_000) * 10_000` (Windows FILETIME 1601-01-01 epoch). The court-pinned code uses the .NET tick epoch (0001-01-01): `(ms + 62_135_596_800_000) * 10_000` — see `delivery_encoder.ex:121-128` (`filetime_from_ms/1`) and the fence at `amqp_dialect.ex:151-152`. Fix the doc to match the code:

> Service Bus filetime lock dialect `(ms + 62_135_596_800_000) * 10_000` (.NET tick epoch, 0001-01-01)

**Grep acceptance:** `grep -rn "11_644_473_600_000" lib/ docs/PACK_INTEGRATION/` → zero hits after the fix; a single filetime constant story across doc+code.

(Forward-log, NOT this WO: `docs/compliance/C5_SERVICEBUS.md:31` flags a separate 10x moduledoc-example drift in `delivery_encoder.ex:122` — `62_135_596_800_000_000` vs `621_355_968_000_000_000` for ms=0. File not owned here; log it forward.)

## 4. Acceptance criteria

1. `mix test test/runtime_contracts_test.exs` green twice consecutively — no diff outside the two owned files; `generated/` and `MANIFEST.sha256` untouched.
2. Doc table rows = 6; moduledoc bullets = 6.
3. `11_644_473_600_000` grep → zero hits in lib/ and PACK_INTEGRATION.
4. `@wired` count (6) == moduledoc bullet count == doc table row count == `contract_count` in the `verify/0` verdict map.

## 5. Out-of-scope / forward-log

- **`contract_name_guess/2` atom creation** (`runtime_contracts.ex:248-261`): `String.to_atom(inspect(entry))` on odd entries creates unbounded atoms at the `verify/1` injection point (no wire path — inputs come from the mutation court). Candidate: `String.to_existing_atom/1` with fallback-to-string, or a cap. Do NOT change in this WO (it would perturb verdict-map name resolution tests).
- The `delivery_encoder.ex:122` 10x moduledoc example (above).
