# Gap 12 (v26.10.31) — Payload Wire-Law Migration Table (charter)

Consolidation lane 12 of 15. Promotes the M2 census
(`docs/jira/posh/v26.10.31/gaps/02-payload-laws-census.md`, ALIVE 2026-10-30) into
the charter migration table. Every "current home" below was re-read from disk
2026-10-30; three rows spot-verified this session:

- **L2 VERIFIED** — `adapters/terraform-provider-smalt/internal/provider/resource_key_vault.go:252,308,341`
  (location emit/normalize/merge) and `arm_client.go:528-529` (`NormalizeLocation`)
  match disk exactly. Census used the `posh/...` prefix; the real root is
  `adapters/terraform-provider-smalt/` (posh's `internal/provider` tree is the Go
  adapter forest — path corrected in this table).
- **L1 VERIFIED** — `lib/smalt/arm_gateway/providers/container_apps.ex:767-782`
  is `validate_environment_ref` (dual-key `managedEnvironmentId`, typed
  `EnvironmentNotFound` 400). Matches census.
- **L7 CORRECTED** — census cited `resource_providers.ex:1412-1418` for the
  `existed? → 200 else 201` law; those lines hold an SbRules PUT that answers 201
  unconditionally. The law actually lives at
  `lib/smalt/arm_gateway/plug/resource_providers.ex:986/1003, 1291/1296, 1639-1642`
  (plus the LRO-gated branch 418/482-498). Census's secondary generic-201 cites
  (`:154,498,4397,4450,4525`) all verified as `send_json(conn, 201, ...)`.

Columns per dispatch: law | current home (file:line) | target home | phase.

## Phase 1 — NEUTRAL-CORE (P1: `smalt-core.ttl` admission layer above registry)

| Law | Current home (file:line) | Target home | Phase |
|---|---|---|---|
| L2 — KV secret top-level `location` envelope (PUT carries `location`; echoed into store row) | `adapters/terraform-provider-smalt/internal/provider/resource_key_vault.go:252,308,341`; `arm_client.go:528-529` (NormalizeLocation); harness `apps/web/test/harness/vault/lib.ts:117,150`; smalt echo via `resource_providers.ex:146` verbatim-props family | smalt-core semantic: generic resource envelope {name, type, location} — not KV-specific | P1 |
| L5 — secret-echo disjunctive law (GET shows new value OR omits it AND bumps etag — a changed secret is never wire-indistinguishable) | harness `apps/web/test/harness/vault/lib.ts:193-210`, `tc-vault-001-retrieval.test.ts:49-60`; polarity registered `docs/jira/posh/v26.10.30/gaps/23-secret-echo-staleness.md` + `posh/KNOWN_DIVERGENCES.md` KD-03 | smalt-core semantic: observable-state disjunction law (state change must be wire-visible through value-or-version) | P1 |
| L7 — 201/200 PUT semantics (created-vs-existed status law, applies to every PUT family) | `lib/smalt/arm_gateway/plug/resource_providers.ex:986/1003, 1291/1296, 1639-1642` (existed? gate), `418/482-498` (LRO branch); generic-201 sites `:154,498,4397,4450,4525` | smalt-core semantic: generic created-vs-updated status law | P1 |
| L8 — ARM LRO 202-poll envelopes (202 + `Azure-AsyncOperation` + `Location` + `Retry-After`, operation poll, terminal flip) | `lib/smalt/arm_gateway/lro.ex:16-28`; `lro_sweeper.ex`; `engine/lro.ex`; gap02-A5 `docs/jira/posh/v26.10.30/gaps/02-smalt-arm-vs-azure.md` | smalt-core: neutral lifecycle vocabulary (decision-record open question 1); envelope render stays dialect until P3 | P1 (vocabulary), render→P3 |
| L10 — etag / If-Match optimistic concurrency (`*` honored, required If-Match on lock actions, typed 409/412) | `lib/smalt/arm_gateway/plug/resource_providers.ex:2137-2217` (lock If-Match gate, deterministic lock etag); ACR `acr_router.ex` etag round-trip; provider `PutWithETag` (`arm_client.go`), `resource_remaining_v1.go:1792,1899`; harness `vault/lib.ts:202-210` | smalt-core semantic: optimistic-concurrency law (vendor-neutral REST) | P1 |
| L11 (mechanism) — uuid5 deterministic mints `uuid5(name\|scope)` with fixed namespace + loud diag | provider `resource_remaining_v1.go:1369,1413-1454` (resolveRoleDefinitionInput, mintDeterministicGUID); `posh/KNOWN_DIVERGENCES.md:83` (KD-09); smalt `lib/smalt/policy.ex`, `lib/smalt/arm/rbac.ex:164,196` | core: deterministic identity-mint law; **the Azure built-in GUID mapping table is the P2 dialect half — one law, split homes** | P1 (mechanism); mapping table→P2 |
| L13 — tags full-replace + null-when-empty; locks covering-scope 409 `ScopeLocked` | `lib/smalt/arm_gateway/plug/common.ex:100-107`; `lib/smalt/arm_gateway/tags_locks.ex:19-62,154` | core: generic cloud-resource metadata + lock semantics | P1 |

## Phase 2 — AZURE-DIALECT (P2: azurerm-dialect shim mapping layer, posh)

| Law | Current home (file:line) | Target home | Phase |
|---|---|---|---|---|
| L1 — managedEnvironmentId dual-key (emit + legacy `environmentId`, accept either, import backfill) | — | provider `adapters/terraform-provider-smalt/internal/provider/resource_container_app.go:1009-1010,1287`; smalt `lib/smalt/arm_gateway/providers/container_apps.ex:767-782`; harness `apps/web/test/harness/container/container.test.ts:83,102-107` | azurerm-dialect shim mapping layer (posh) | P2 |
| L3 — numeric memory (ACA quota in GiB numbers; provider retries "1Gi"→numeric on 400 `resources.memory`) | — | provider `resource_container_app.go:590,605,623-635,1155`; smalt `container_apps.ex:1141-1151` (`is_number(memory)`); harness `container/container.test.ts:4` | azurerm-dialect shim (unit coercion beside ACA mapping) | P2 |
| L4 — traffic-on-update-only (no traffic weight on first PUT; update merges config; entries bind real revisions, sum 100, single latest) | — | smalt `container_apps.ex:104,1003,219-239`; provider `resource_container_app.go:1104-1120,1032-1038`; harness `container/container.test.ts` | azurerm-dialect shim (ACA revision/traffic mapping) | P2 |
| L6 — api-version ladders / monotonic ceilings | — | smalt `registry.ex` `@api_versions` + `:210-220`; `plug/common.ex:318-348` (KD-78 gate); provider ladders `resource_key_vault.go:189-198`, `resource_container_app.go:640-673`, `resource_remaining_v1.go:1633-1636`; skew matrix `docs/jira/posh/v26.10.30/gaps/24-cross-repo-skew.md` | azurerm-dialect shim — decision record: "api-version ceilings move into the dialect layer" | P2 (explicit in decision record) |
| L8b — Location-only (non-async) LRO variant | — | registered divergence only (gap02 A5, `docs/jira/posh/v26.10.30/gaps/02-smalt-arm-vs-azure.md`) | registered KD row; dialect only if a consumer waiter needs it | P2 |
| L9 — resourceGroups casing tolerance (case-insensitive ids on the wire, downcased store keys) | — | smalt `provider_state.ex:87`, `tags_locks.ex:154`, `acr_router.ex:24-67`, `common.ex:639-649,746`; provider `arm_client.go:485-490` (NormalizeARMID) | azurerm-dialect shim (ARM id syntax = Azure vocabulary) | P2 |
| L11 (mapping table) — Azure built-in GUID table (built-in role definition ids) | — | smalt Policy face `lib/smalt/policy.ex`, `lib/smalt/arm/rbac.ex:164,196` | dialect carries the mapping table; core carries only the uuid5 mechanism | P2 |
| L12 — `2023-06-preview` day-less normalization (`-preview` stripped before date compare; malformed never admitted) | — | smalt `common.ex:318-348` (`version_base`, KD-78); provider `resource_remaining_v1.go:1633-1636`; AcrRouter precedence fix per gap24 S1 | azurerm-dialect shim (pairs with L6) | P2 |

## Divergences from the source census (recorded, not silently fixed)

1. **Provider root path corrected**: census wrote `provider internal/provider/...`
   implying `posh/internal/provider`; on disk the tree is
   `adapters/terraform-provider-smalt/internal/provider/`. All Go citations above
   use the verified root.
2. **L7 primary citation replaced** (see header): `:1412-1418` holds an
   unconditional-201 SbRules handler; the `existed? → 200 else 201` law is at
   `:986/1003, :1291/1296, :1639-1642` (+ LRO branch `:418/482-498`).
3. **L8b split noted** (per L11's pattern): L11 is mechanism-neutral /
   table-dialect; L8b is recorded as its own dialect row so the
   Location-only variant is not silently absorbed into L8's core vocabulary.

## Phase boundaries (from census "Migration reading")

- **P1** lands `smalt-core.ttl` additively above the registry families — no wire
  change; all seven P1 laws are vendor-neutral REST/cloud semantics.
- **P2** grows dialect #2 (azurerm shim in posh) translating Azure vocabulary
  INTO core semantics; wire stays byte-identical through P2.
- **P3** (invert ARM face): nothing in this census blocks P3; the L8 neutral
  lifecycle vocabulary is the gating design item (decision-record open question 1).
