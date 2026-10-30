# Gap 02 (v26.10.31) — Wire-Law Census: Azure-Dialect vs Neutral-Core

Migration lane 2 of 17. Census of every wire law absorbed this wave, with current
home(s) (file:line, re-read from disk 2026-10-30), classification (AZURE-DIALECT →
migrates into the azurerm shim's mapping layer; NEUTRAL-CORE → becomes smalt-core
semantics), target home, and migration phase per the additive path in
`docs/jira/posh/v26.10.31/00-unification-dialect-decision.md`:

- **P1** — land `smalt-core.ttl` as admission layer ABOVE the existing registry
  families (no wire change).
- **P2** — grow dialect #2 (azurerm dialect as first real consumer) mapping into
  the core; dialect vocabulary lives in posh.
- **P3** — only then evaluate inverting the ARM face into posh.

## Census table

| # | Law | Current home(s) (file:line) | Class | Target home | Phase |
|---|-----|------------------------------|-------|-------------|-------|
| L1 | **managedEnvironmentId dual-key** (emit `managedEnvironmentId` + legacy `environmentId`, accept either; import backfills from response) | provider `internal/provider/resource_container_app.go:1009-1010` (dual emit), `:1287` (import backfill); smalt face validates env row, typed 400 `EnvironmentNotFound` (`lib/smalt/arm_gateway/providers/container_apps.ex:767-782`); harness witness `apps/web/test/harness/container/container.test.ts:83,102-107` | AZURE-DIALECT | azurerm-dialect shim mapping layer (posh) | P2 |
| L2 | **KV secret top-level location** (PUT body carries top-level `location`; echoed into store row) | provider `resource_key_vault.go:252,308,341` (+ `NormalizeLocation` `arm_client.go:528-529`); harness `apps/web/test/harness/vault/lib.ts:117,150`; smalt echoes `body["location"]` via generic record build (`resource_providers.ex:146` family, `build_resource_record` verbatim-props law) | NEUTRAL-CORE | smalt-core semantic: generic resource envelope {name, type, location} — not KV-specific | P1 |
| L3 | **numeric memory** (ACA quota is a number of GiB; provider retries "1Gi"→numeric on 400 `resources.memory`) | provider `resource_container_app.go:590` (`parseMemoryGiB`), `:605,623-635` (retry), `:1155` (emit); smalt `container_apps.ex:1141-1151` (`is_number(memory)`); harness `container/container.test.ts:4` | AZURE-DIALECT | azurerm-dialect shim (unit coercion next to the ACA mapping) | P2 |
| L4 | **containerApps traffic-on-update-only** (no traffic-weight on first PUT; update merges existing config, entries bind real revisions, sum 100, single latest) | smalt `container_apps.ex:104,1003` (`validate_traffic_revisions` on merged), `:219-239` (single-mode platform act skips check); provider `resource_container_app.go:1104-1120` (emit), `:1032-1038` (update merge); harness `container/container.test.ts` | AZURE-DIALECT | azurerm-dialect shim (ACA revision/traffic mapping) | P2 |
| L5 | **secret-echo disjunctive law** (GET either shows the new value or omits it AND bumps etag — a changed secret is never indistinguishable from an unchanged one) | harness `apps/web/test/harness/vault/lib.ts:193-210` (disjunction assert), `tc-vault-001-retrieval.test.ts:49-60`; substrate polarity registered in smalt `docs/jira/posh/v26.10.30/gaps/23-secret-echo-staleness.md` (live probe: ARM face echoes value verbatim) + `posh/KNOWN_DIVERGENCES.md` KD-03 | NEUTRAL-CORE | smalt-core semantic: observable-state disjunction law (vendor-neutral: state change must be wire-visible through value-or-version) | P1 |
| L6 | **api-version ladders / monotonic ceilings** (registry `@api_versions` tops, monotonic `version_lte?` gate, provider fallback ladders) | smalt `registry.ex` `@api_versions` + `:210-220` (lattice), `arm_gateway/plug/common.ex:318-348` (KD-78 monotonic gate, preview strip); provider ladders `resource_key_vault.go:189-198`, `resource_container_app.go:640-673`, ACR const `resource_remaining_v1.go:1633-1636`; per-type matrix in smalt `docs/jira/posh/v26.10.30/gaps/24-cross-repo-skew.md` | AZURE-DIALECT | azurerm-dialect shim (Azure vocabulary) — decision record names this explicitly: "api-version ceilings move into the dialect layer" | P2 (explicit in decision record) |
| L7 | **KV secret 201/200 create/update semantics** (PUT answers 201 when new, 200 when record existed) | smalt `resource_providers.ex:1412-1418` (`existed? → 200 else 201`); live witness `docs/jira/posh/v26.10.30/gaps/23-secret-echo-staleness.md` (secret PUT → 201, echo probe); generic `201` sites `:154,498,4397,4450,4525` | NEUTRAL-CORE | smalt-core semantic: generic ARM/CRUD created-vs-updated status law (applies to every PUT family, not KV) | P1 |
| L8 | **ARM LRO 202-poll envelopes** (202 + `Azure-AsyncOperation` + `Location` + `Retry-After`, operation resource poll, terminal flip) | smalt `lib/smalt/arm_gateway/lro.ex:16-28` (contract), `lro_sweeper.ex` (single-writer sweeper), `engine/lro.ex`; gap02 row A5 (`docs/jira/posh/v26.10.30/gaps/02-smalt-arm-vs-azure.md` table) | NEUTRAL-CORE | smalt-core semantic: neutral lifecycle vocabulary (decision-record open question 1 names LRO envelopes as the core-level equivalent to find — TOSCA/CIMI scan inputs) | P1 (as core lifecycle vocabulary), envelope render stays dialect until P3 |
| L8b | **Location-only (non-async) LRO variant** | registered divergence only (gap02 A5) | AZURE-DIALECT | registered KD row; dialect if a consumer waiter needs it | P2 |
| L9 | **resourceGroups-casing tolerance** (ids case-insensitive on the wire, downcased store keys; provider NormalizeARMID) | smalt `provider_state.ex:87`, `tags_locks.ex:154`, `acr_router.ex:24-67`, `common.ex:639-649,746`; provider `arm_client.go:485-490` (`NormalizeARMID`) | AZURE-DIALECT | azurerm-dialect shim (ARM id syntax is Azure vocabulary) | P2 |
| L10 | **etag / If-Match optimistic-concurrency law** (PutWithETag, `*` honored, required-If-Match on lock actions, typed 409/412 mismatch) | smalt `resource_providers.ex:2137-2217` (lock If-Match gate, deterministic lock etag), ACR `acr_router` etag round-trip; provider `PutWithETag` (`arm_client.go`), `resource_remaining_v1.go:1792,1899`; harness `vault/lib.ts:202-210` (etag cross-check) | NEUTRAL-CORE | smalt-core semantic: optimistic-concurrency law (etag/If-Match is vendor-neutral REST semantics) | P1 |
| L11 | **uuid5 deterministic mints** (`uuid5(name\|scope)` LOCAL GUID with fixed namespace; loud warning diag; built-in GUID mapping table is the close) | provider `resource_remaining_v1.go:1369,1413-1454` (`resolveRoleDefinitionInput`, `mintDeterministicGUID`); KD-09 register `posh/KNOWN_DIVERGENCES.md:83`; smalt Policy face resolves real built-in GUIDs (`lib/smalt/policy.ex`, `lib/smalt/arm/rbac.ex:164,196`) | NEUTRAL-CORE (mechanism) + AZURE-DIALECT (the GUID table) | core: deterministic identity-mint law (uuid5(name\|scope) with named namespace); dialect carries the Azure built-in GUID mapping table | P1 (mechanism), P2 (mapping table) |
| L12 | **2023-06-preview day-less normalization** (`-preview` stripped before date compare; malformed never admitted) | smalt `common.ex:318-348` (`version_base`, KD-78); provider comment+const `resource_remaining_v1.go:1633-1636`; AcrRouter precedence fix referenced gap24 S1 | AZURE-DIALECT | azurerm-dialect shim (Azure api-version vocabulary; pairs with L6) | P2 |
| L13 | **tags full-replace + null-when-empty**, locks covering-scope 409 `ScopeLocked` (parity rows A8/A9, gap02) | smalt `common.ex:100-107`, `tags_locks.ex:19-62,154`; tagged in gap02 as NONE (parity) | NEUTRAL-CORE | core (generic cloud-resource metadata + lock semantics) | P1 |

## Status line

ALIVE — every "current home" citation above was re-read from disk this session
(provider Go, smalt lib, courtroom harness, gap docs); L5/L7/L8b/L13 partially
rest on same-session gap-doc receipts (gaps/02, 23, 24, 49, KD register), which
are themselves 2026-10-30 receipts. All 14 laws have a classification, target
home, and phase. Open inputs the census could NOT find on disk: no
`smalt-core.ttl` exists yet (P1 target surface — nothing to point at), and the
LRO neutral-vocabulary shape is decision-record open question 1, unresolved.

**P1 shard update (2026-10-30, lane M2)**: the P1 input shard exists and is
lane-8-ready — `docs/jira/v26.10.31/gaps/02-p1-core-ttl-shard.md` (7 shape
requirements for L2/L5/L7/L8/L10/L11/L13, each with a refusal falsifier;
vocabulary tosca:/cimi:/kmip:/sec: only). Lane M2's same-session re-grep found
two drifts vs this table: `resource_providers.ex` now lives under
`lib/smalt/arm_gateway/plug/` (cited unqualified for L2/L7/L10/L13), and the
`apps/web/test/harness/...` paths (L1/L2/L5) do not exist in the smalt tree —
they are posh-tree paths; re-home before relying on them. Shard is INPUT only;
lane 8 owns the ttl merge.

## Migration reading

- **P1 (core, additive over registry):** L2, L5, L7, L8 (lifecycle vocabulary),
  L10, L11 (mechanism), L13 — all vendor-neutral REST/cloud semantics that the
  core admits above the registry without touching wire behavior.
- **P2 (dialect #2, azurerm shim mapping layer in posh):** L1, L3, L4, L6, L8b,
  L9, L12, L11's GUID mapping table — Azure-vocabulary laws that the azurerm
  dialect translates INTO core semantics; these must remain byte-identical on
  the wire through P2 (the wire-proven azurerm swap depends on it).
- **P3 (invert ARM face):** nothing in this census blocks P3; the L8
  neutral-lifecycle vocabulary is the gating design item (open question 1).
