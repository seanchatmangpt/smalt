# arm-gateway

ARM-style control plane (port 9443) and its TLS twin (9444). Reference is
generated from the code surface; regenerate by re-grepping the cited files.

## Modules

Derived: `grep -h "^defmodule" lib/smalt/arm_gateway/*.ex`

| module | file |
|---|---|
| `Smalt.ArmGateway.Defaults` | `lib/smalt/arm_gateway/defaults.ex` |
| `Smalt.ArmGateway.LRO` | `lib/smalt/arm_gateway/lro.ex` |
| `Smalt.ArmGateway.LRO.Sweeper` | `lib/smalt/arm_gateway/lro_sweeper.ex` |
| `Smalt.ArmGateway.ProviderMatrix` | `lib/smalt/arm_gateway/provider_matrix.ex` |
| `Smalt.ArmGateway.Router` | `lib/smalt/arm_gateway/router.ex` |

## Config keys

Derived: `grep get_env(:smalt` over `lib/smalt/arm_gateway/`; defaults from
`config/config.exs` / `lib/smalt/application.ex` call sites.

| key | default | set at |
|---|---|---|
| `:arm_port` | `9443` | `lib/smalt/application.ex:69` |
| `:arm_tls_port` | `9444` | `lib/smalt/application.ex:119` |
| `:arm_rate_limit` | `:infinity` | `lib/smalt/arm_gateway/router.ex:124` |
| `:lro_delay_ms` | `0` | `lib/smalt/arm_gateway/lro.ex:34` |
| `lro_sweep_interval_ms` | `30_000` | `lro_sweeper.ex` |
| `:lro_retention_ms` | `:infinity` | `lro_sweeper.ex:97` |
| `:sts_signing_secret` | `nil` (required in prod; refusal if `:prod` and nil) | `router.ex:304` |
| `:prod` | unset (truthy = prod-mode secret gate) | `router.ex:337` |
| `:egress_port` | `8443` | `router.ex:3677` |

## Refusal vocabulary (arm-gateway surface)

Generated from `docs/ERROR_CODES.md` `arm-gateway` rows (regenerate with
`just gen-error-codes`; drift-fenced by `test/error_codes_doc_test.exs`):

- 400: InvalidAction, InvalidApiVersionParameter, MissingApiVersionParameter,
  InvalidResourceShape, InvalidFilter, InvalidAction, LocationMismatch,
  InvalidApiVersionParameter (arm_gateway/router.ex:952, paired status pending — see
  the ERROR_CODES drift fence receipt), PolicyViolation
- 404: ActionNotFound, OperationNotFound, ResourceGroupNotFound,
  ResourceNotFound, RouteNotFound, RuleNotFound, SubscriptionNotFound
- 409: SecretVersionNotFound
- 412: PreconditionFailed
- 200-body: OperationRecordIncomplete (LRO terminal poll, `lro.ex:184`)

GraphLaw ontology admission refusal is pinned at 400 InvalidResourceShape
(ARM never 422); admitted types from `Smalt.Registry.admitted_resource_types/0`.

## KD cross-links

Canonical register: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`. Every
divergence named here links its row there; the table is ground truth.

- KD-24 double-slash generic PUT 404s (real ARM collapses `//`)
- KD-25 shape gate requires `properties.skuName` (real ARM takes `sku.name`)
- KD-26 LRO terminal record lacks `provisioningState`
- KD-27 metadata `resourceManagerEndpoint` hardcodes port 9443
- KD-28 NSG shape admits malformed PUT (`sh:closed false`)
- KD-29 virtualNetworkLinks admitted type with no PUT route
- KD-30 locations route 404
- KD-31 list-by-rg 404
- KD-32 RG PATCH 404
- KD-54 subscription-wide resource LIST missing (KD-54)
- KD-55 provider surface holes (tenant/providers routes)
- KD-56 provider register/unregister
- KD-57 generic PATCH falls to diagnostic
- KD-58 tag operations 404
- KD-59 export/move/validateMove 404
- KD-78 api-version cap pins resourceGroups at 2021-04-01 vs azurerm 4.54
- KD-79 Key Vault vaultUri loopback-by-design (see
  `Smalt.ArmGateway.Defaults` enrich surface, `defaults.ex`)
- KD-80 metadata trailing-slash join semantics
- KD-81 LRO terminal poll body identity
- KD-82 `*Services/default` singleton GET synthesis
- KD-83 blobServices lattice pinned at 2021-04-01
- KD-87 STS token path double-slash tolerance
- KD-91 `CheckNameExists` HEAD existence check (cosmos via ARM)
- KD-92 ARM-container vs data-plane container store split

## See Also

- `docs/ERROR_CODES.md` (generated; `just gen-error-codes`)
- `docs/reference/kd-register.md` (pointer to canonical register)
- `docs/reference/ets-tables.md` (store tables the router writes)
