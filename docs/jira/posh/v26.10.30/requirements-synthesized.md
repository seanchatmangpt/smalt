# POSH → smalt: Synthesized Requirements (final, 2026-10-30)

Derived from the 20-agent Explore wave + implementation receipts. Normative.
Companion docs: charter-master.md, triz.md, working-backwards.md, dfcharter/*.

## Architecture requirement (settled)

POSH = asymmetric membrane inside smalt, tri-tier per the SPAF contract:
1. BEAM core (smalt) — state, supervision, orchestration; never raw
   crypto/byte-unpacking on actor heaps.
2. Go adapter (stateless) — Terraform provider + Azure/K8s protocol shims;
   zero domain state, zero persistent DBs.
3. `#![no_std]` Rust BLAKE3 kernel — 32-byte Merkle receipts, CC=1, no heap
   allocs (Phase 4; v1 uses SHA-256 honestly named as such).

## Hard requirements

1. Invisible azurerm swap: configs byte-unchanged via dev_overrides — TF 1.14
   REJECTS labeled dev_overrides blocks (attribute form only, witnessed live).
2. Transport: kind cluster, host 9443 -> node 30943, plain-HTTP ARM face;
   /metadata/endpoints is the only auth-exempt health anchor on 9443 (/healthz
   is bearer-gated there; lives on egress 8443).
3. Auth: STS mint POST {endpoint}/{tenant}/oauth2/v2.0/token,
   client_credentials, zero-guid client, secret smalt-sovereign-mock-secret;
   token cached to expiry-60s.
4. API-version gate is monotonic per type (KD-78): registry.ex is the
   authority — resourceGroups 2023-07-01, containerApps/managedEnvironments
   2023-05-01, vaults 2023-02-01, secrets 2023-07-01, UAI 2023-04-01, FIC
   2023-01-31 (flat RG-scope), ACR 2023-06-preview (required version_base
   day-less normalization + AcrRouter precedence fix). 2024-03-01 ladders
   are refused.
5. Substrate divergences the provider must absorb: managedEnvironmentId (not
   environmentId); KV secret PUT needs top-level location; containerApps
   refuse traffic-weight on first PUT; numeric memory (not "1Gi"); secrets
   never echoed on read (keep prior state); GraphLaw ontology admission
   decides which types exist — gaps close via ontology.ttl + regen, NEVER
   hand-editing registry.ex.
6. Receipt law: every mutation passes the turnstile
   (BLAKE3(delta || node || ts || stateRoot), 32 bytes, v1 SHA-256
   [CORRECTED 2026-10-31: this four-input formula is superseded — see the
   v26.10.31 ADDENDUM at the end of this file; the live cross-language
   contract is BLAKE3(op ‖ ts_ns ‖ payload_body). Original text preserved
   as history.]),
   append-only prev-hash-chained event log; no unreceipted delta admitted
   (type-signature fence). HONEST CAVEAT (2026-10-30, G26, see
   gaps/26-turnstile-live-path.md): only the receipt STAMP (header emit +
   posh-smalt-wire assert) is ALIVE today; the FENCE half — refuse an
   unreceipted delta + settle into the event log — is enforced nowhere live
   until lane 39 lands. This clause is the requirement lane 39 implements.
7. Turtle/ggen: routing/admission policies as .ttl + SHACL; ggen sync
   requires a ggen.toml manifest in the pack (FM-CONFIG-001); templates
   project Elixir GenStage + Go adapters; hand-written code = irreducible
   residue only.
8. Verification: fail-closed courts with loud typed skips (exit 3) —
   falsifiers: STS-bearer wire inspection + destroy + zero residue,
   plan -detailed-exitcode = 0, non-vacuity mutations must flip every gate
   (a court that cannot flip is FAIL).
9. Docker/colima must be up; egress allowlist default-deny (fail-closed boot
   on missing posh.yaml); role_definition is GET-only on smalt (create-local
   + loud UNSUPPORTED only).

## v26.10.31 ADDENDUM (2026-10-31)

Addenda only — nothing above is deleted. Every item verified against the cited
v26.10.31 gaps files on disk this session.

### 1. Dialect layer (per `v26.10.31/gaps/01-sts-migration.md`)

- Decision record: `v26.10.31/00-unification-dialect-decision.md` governs the
  reclassification. The existing ARM face is reclassified from native
  semantics to **dialect #1 (Azure ARM/azurerm dialect)**; the STS wire face
  (Entra-shaped mint/discovery/JWKS plug) is classified **dialect #0 — the
  identity dialect**, preceding dialect #1. Consumers reaching the STS through
  the Azure-dialect token endpoint are dialect consumers.
- api-version ceilings (KD-78 tops, L6/L12 in `gaps/02-payload-laws-census.md`)
  move into the dialect layer per the decision record; `registry.ex` remains
  the generation source, not a hand-edited artifact.

### 2. Turnstile digest correction (per `v26.10.31/gaps/14-turnstile-neutrality.md`)

The four-input formula in Hard Requirement 6 above
(`BLAKE3(delta || node || ts || stateRoot)`) is **corrected by reference**: the
actual cross-language contract, pinned by vector `0c39d201…db834` and enforced
identically in `settlement.ex:58-68`, `receipt_turnstile.ex:22-23`, and the Go
verifier `posh/internal/receipt/verify.go` (`VerifyTurnstile`), is

    BLAKE3(op_utf8 || u64BE(timestamp_ns) || payload_body)

— three inputs, no length prefixes, no separators. The delta IS the body;
`node_id` and `state_root` are event-log entry fields, not digest inputs. Any
charter text carrying the four-input formula is a false citation (gaps/14,
"Violations / corrections found", item 1).

### 3. KD-78 ceiling table as amended by C4

C4 raised the `registry.ex` `@api_versions` tops (verified on disk at
`/Users/sac/smalt/lib/smalt/registry.ex:140-186` this session):

| Type | Top (raised) |
|---|---|
| Microsoft.OperationalInsights/workspaces | 2022-10-01 |
| Microsoft.ContainerService/managedClusters (AKS) | 2024-02-01 |
| Microsoft.ManagedIdentity/federatedIdentityCredentials | 2023-08-01 |
| Microsoft.KeyVault/vaults (incl. keys, secrets) | 2023-07-01 |
| Microsoft.Network/* (vNets, NSGs, NICs, public IPs, …) | 2023-05-01 |
| Microsoft.App/managedEnvironments | 2023-05-01 (registry row present, unchanged) |

ACR gate fix: the provider pins `acrAPIVersion = "2023-06-01"`
(`resource_remaining_v1.go:1636`); the face-side gate in
`lib/smalt/arm_gateway/providers/acr_router.ex` admits any version whose
version_base date is <= 2023-06-01 (including `2023-06-preview`, normalized
day-less) and refuses above with the typed `InvalidApiVersionParameter`
envelope.

### 4. Closed rows

- **roleDefinition LIVE (C1)**: `azurerm_role_definition` is no longer
  GET-only/UNSUPPORTED — the smalt ARM face mounts roleDefinitions
  GET/PUT/DELETE (`resource_providers.ex:4550-4566`, `lib/smalt/arm/rbac.ex`)
  and the provider performs real PUT/GET/DELETE
  (`resource_remaining_v1.go:1043-1260`). KD-01 closed; coverage gate
  `7 registered / 13 pass / 0 missing / 20 cells`, exit 0. This supersedes
  Hard Requirement 9's "role_definition is GET-only on smalt" clause.
- **Imports implemented (C8)**: all 12 consumer `import {}` blocks are covered
  by executable import assertions (`import_state_test.go`, 6 test funcs;
  `go test ./... -run Import` green 2026-10-30); 9-type roundtrip court green
  per L48 (`v26.10.30/gaps/48-import-roundtrip-execution.md`).

Standing of this addendum: ALIVE (every claim re-verified against the cited
files on disk 2026-10-31; no history above deleted).

## Dialect layer (v26.10.31)

Added by GAP-15 wave-2 doc migration (lane 15). Decision record:
`../v26.10.31/00-unification-dialect-decision.md` (DECIDED, 2026-10-30).

The tri-tier architecture requirement above (settled) reclassifies as
follows, additively — no requirement text above is rewritten:

- The Go adapter's "Azure/K8s protocol shims" are **dialect faces**, not core:
  a dialect is a vendor translation layer living in posh, never in smalt-core.
- A **neutral-core admission layer** sits above the registry families:
  smalt-core is a vendor-neutral public-cloud ontology (TOSCA/CIMI prior art
  first); api-version ceilings reclassify to the dialect layer.
- **Azure ARM = dialect #1** (the current face); **Entra STS wire face =
  dialect #0** (identity; verdict per
  `../v26.10.31/gaps/01-sts-migration.md`).

Dialect-#1-scoped requirements above (azurerm swap, ARM face, azurerm schema
parity) keep their acceptance criteria unchanged; their scope is now declared
dialect-#1 rather than core.
