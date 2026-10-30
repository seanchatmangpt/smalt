# Gap 03 — provider mapping inventory: DIALECT-SHIM vs GENERIC-CLIENT (migration lane 3)

Date: 2026-10-30. Migration wave v26.10.31, lane 3 (read-mostly). Subject trees:
`/Users/sac/smalt/adapters/terraform-provider-smalt/internal/provider/` (provider side) and
`/Users/sac/smalt/posh/internal/armclient/` (posh side). Companion to gap 08 (k8s census)
and `00-unification-dialect-decision.md`; this inventory is the seed of posh's first dialect
package beyond Terraform.

Status line: **PARTIAL → PARTIAL_ALIVE (wave-2 gap lane 3, 2026-10-30)** — the deep
azurerm-specific coercions inventoried below now have Go dialect translations in
`posh/internal/dialect/azure/family_translate.go` (KD-05 memory coercion, KD-04
create-traffic strip, #6 managedEnvironmentId dual-key, #2 KV secret ID geometry +
deterministic version, #3/#3a deterministic GUID mints incl. KD-09 roleDef and the
acr-pwd / law-ws / law-key / st-key mints, #5 NormalizeARMID + canonical tables) with
table + mutation-probe tests in `family_translate_test.go` (`go build`/`go vet` exit 0;
all 15 lane tests PASS). Original PARTIAL census follows.

Original status (wave-1, read-only lane): **PARTIAL** — every disposition below is on-disk evidence from the provider
tree (named functions read in full; census of arm_client.go, retry.go, import_state.go,
key_vault_secret.go, resource_container_app.go, resource_remaining_v1.go). The posh overlap
column comes from `posh/internal/armclient/client.go` (257 lines, read in full). What is
PARTIAL: read-only lane — no posh-side compile/test was executed; "posh already has" claims
are surface-census claims, not integration-tested.

## Method

Classification law (lane contract): azurerm-specific coercion/mapping → posh's azurerm
dialect package; provider-neutral machinery (retry/backoff, ApiError, token cache,
singleflight, request timeout, honesty-law diag machinery, import-segment assertion
mechanics) → stays neutral. Classify each named subject with file:line evidence.

## Inventory

Legend: DIALECT-SHIM = azurerm-specific → azurerm dialect package; GENERIC-CLIENT =
neutral → shared client core; MIXED = genuinely both, split noted.

| # | Subject (file:line) | Class | Notes |
|---|---|---|---|
| 1 | `coerceNumericMemoryInBody` (resource_container_app.go:610; helpers parseMemoryGiB :590, isMemoryNumberValidationError :602) | DIALECT-SHIM | Container-App body reshape keyed on `properties.template.containers[].resources.memory` — azurerm wire shape → dialect. Helpers: parseMemoryGiB unit-stripping (Gi/G/Mi/M) is generic quantity parsing but the 0.5-GiB default is Container-App-specific; isMemoryNumberValidationError wraps the neutral ApiError with a dialect body substring ("resources.memory"). Mostly dialect; ApiError dependency is the neutral seam. |
| 2 | `populateSecretState` keep-prior (resource_key_vault_secret.go:356) | MIXED | Keep-prior law itself ("wire omitted a field → preserve prior state → zero plan drift") is provider-neutral — the azurerm dialect base layer wants it as a shared pattern; the ID geometry it constructs (versionless/full/resource IDs, `https://{vault}.vault.azure.net/secrets/...`) is pure Key Vault wire shape → dialect. |
| 3 | `resolveRoleDefinitionInput` (resource_remaining_v1.go:1426) | DIALECT-SHIM | Azure RBAC funnel: ARM ID detection (`/providers/microsoft.authorization/roledefinitions/`), scope-scoped minting `uuid5(name\|scope)`, KD-09 built-in-role-GUID honesty warning. All azurerm; its diag emission goes through the neutral machinery (#11). |
| 3a | `mintDeterministicGUID` (resource_remaining_v1.go:38) | MIXED | uuid5-style SHA-1+namespace GUID mint: the *mechanism* is neutral, the *namespace bytes* (roleDefUUIDNamespace :36) and every call site are azurerm. Move mechanism neutral, keep namespace constant in dialect. |
| 4 | `carryOrMintIdentityAttr` (resource_remaining_v1.go:475) | MIXED | carry-prior-vs-refuse-vs-mint ladder: prior state wins; no prior → typed UNSUPPORTED refusal (honesty law default) or TFPOSH_ALLOW_FABRICATED_IDS=1 loud-warning downgrade; fallback mint is #3a. The *ladder* is a neutral fabrication-ladder pattern; the *application* (client_id/principal_id, azurerm_user_assigned_identity naming in diags) is azurerm. |
| 5 | `NormalizeARMID` (arm_client.go:490) | DIALECT-SHIM | ARD-AZ-01 ARM ID canonicalization: subscriptions/resourceGroups/providers segment case laws, canonicalNamespaces/canonicalResourceTypes tables (arm_client.go ~460-489). The two-segment-walk shape is generic ID canonicalization; the segment vocabulary is ARM. Anchors the dialect package's ID module (extractResourceGroupFromID and import helpers depend on it). |
| 6 | managedEnvironmentId dual-key (resource_container_app.go:1007-1009 write, :1287-1289 read-back) | DIALECT-SHIM | Classic azurerm dual-key wire compat: build writes both `managedEnvironmentId` and `environmentId`; read prefers `managedEnvironmentId`. No neutral component. |
| 7 | `isInvalidAPIVersionError` fallback ladders (resource_key_vault.go:186, applied in putKeyVault :191-207 incl. 202-LRO re-GET; same pattern in putContainerApp resource_container_app.go:643-651) | MIXED | Ladder *mechanics* (PUT fails with typed status+body marker → retry with pinned fallback API version; then 202-LRO-envelope → re-GET persisted record) are generic client machinery worth promoting to the neutral core; the error markers ("InvalidApiVersionParameter") and version constants are dialect. |
| 8 | import_state.go require/forbid segment assertions (import_state.go:22-61) | MIXED | `requireImportSegment`/`forbidImportSegment` mechanics (case-insensitive marker check → typed error diag, never silent wrong-resource adoption, GAP22-3) are provider-neutral; the markers are per-resource-type dialect constants; `setImportIDRGName` is dialect (resource_group_name attr). Mechanics neutral, markers dialect. |
| 9 | retry.go ApiError + retry machinery (retry.go:24-34 ApiError, retryable :37, requestTimeout :46-60, retryAfter/backoffDelay :62-88, doWithRetry :93-120, closeAndRead :133) | GENERIC-CLIENT | Exponential full-jitter backoff, Retry-After honor, 429/5xx retryable, TFPOSH_TIMEOUT request timeout, 1MiB body truncation. Provider-neutral throughout. |
| 10 | arm_client.go token cache / singleflight (Client struct arm_client.go:38-47 `refreshing chan struct{}`, Token :102 singleflight channel coalescing with context.WithoutCancel, mintToken :152, parseJWTExpiry :200) | GENERIC-CLIENT | JWT-expiry-parsed token cache, singleflight mint coalescing, 60s early-refresh — neutral. |
| 11 | honesty-law diag machinery (resource_remaining_v1.go:54-96: allowFabricatedIDs, refuseFabricatedValue, fabricatedValueWarning) | GENERIC-CLIENT | Neutral mechanism: allow-env-var downgrade, typed UNSUPPORTED refusal vs loud warning, both naming the limitation. Consumers (#3/#4) are dialect applications; the mechanism carries zero ARM vocabulary. |

## Posh overlap analysis (posh/internal/armclient, client.go 257 lines)

| Piece | Posh side | Provider side | Delta |
|---|---|---|---|
| Token cache | `Client{mu, token, exp}` client.go:66; getToken :143 mutex-serialized, mintToken :92 uses ExpiresIn with 60s early refresh | arm_client.go:38-47 + Token :102: JWT-expiry parsing + `refreshing chan` singleflight | Posh cache exists but no singleflight coalescing (mutex serializes, does not collapse concurrent mints into one STS hit) and no JWT-expiry parsing. |
| ApiError | `APIError{Status, BodyText}` client.go:158 + typed sentinels ErrUnauthorized/ErrServer/ErrTransport/ErrTurnstile/ErrUnexpectedStatus :36-53 | `ApiError{Status, Body, Method, Path}` retry.go:24 | Provider shape is a superset (Method/Path). Posh's typed-sentinel vocabulary is richer at the error-class level; adopt provider's field set, keep posh sentinels. |
| Retry/backoff | none (grep retry → 0 hits in client.go) | retry.go full layer (jitter, Retry-After, maxAttempts=4, ctx-cancel aware) | Posh has NO retry layer. |
| Request timeout | none | TFPOSH_TIMEOUT env → per-request context timeout | Posh has none. |
| Turnstile receipt verification | verifyTurnstileHeaders :227, TurnstileOp :31 | absent in provider tree | Posh-only; the neutral core keeps it. |
| ETag/If-Match | none (Do returns body+status only) | GetRaw/PutWithETag/DeleteRaw (arm_client.go:340/360/396) | Provider-only; neutral candidate. |
| Import-segment assertions | none | import_state.go | Provider-only; mechanics port neutral, diag plumbing rebinds to posh's diag vocabulary (provider uses tf-plugin-framework diag; posh has none). |
| Honesty-law machinery | none in armclient | remaining_v1.go:54-96 | Provider-only; neutral candidate (needs a posh-side diag/warning channel). |

## Net transfer shape

- Neutral core (posh gains): retry.go wholesale (#9), request timeout (#9), singleflight
  token coalescing + JWT-expiry cache (#10), ApiError field set (#9), API-version fallback
  ladder mechanics + 202-LRO re-GET (#7 mechanics), import-segment assertion mechanics
  (#8 mechanics), fabrication-ladder mechanism (#11).
- Azurerm dialect package (posh gains as `dialect/azurerm` or equivalent): NormalizeARMID +
  canonical tables (#5), resolveRoleDefinitionInput (#3), carryOrMintIdentityAttr
  application (#4), mintDeterministicGUID + roleDefUUIDNamespace (#3a dialect half),
  coerceNumericMemoryInBody (#1), populateSecretState ID geometry (+#2 dialect half),
  managedEnvironmentId dual-key (#6), all API-version constants and error-marker strings,
  import markers + setImportIDRGName (#8 dialect half), keyVault/containerApp ARM path
  builders.
- Keep-prior (#2) and the GUID-mint mechanism (#3a) are the two shared patterns that
  should land in the dialect base layer, not per-resource code.

## Receipt

- Commands: read + census only (`ls`, `wc -l`, `grep -n`, `sed -n`) over
  `/Users/sac/smalt/adapters/terraform-provider-smalt/internal/provider/` and
  `/Users/sac/smalt/posh/internal/armclient/`. Exit 0 throughout. No writes to either
  subject tree (this gaps doc is the lane's single output).
- Verification ladder: narrow (file census) → targeted reads of all 11 named subjects at
  cited lines. No tests executed (read-only lane; compile/test is the integrating lane's
  gate).
