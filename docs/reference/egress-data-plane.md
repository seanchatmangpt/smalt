# egress-data-plane

Egress router (port 8443) and the data-plane services it serves. Generated
from the code surface.

## Modules

Derived: `grep -h "^defmodule" lib/smalt/data_plane/*.ex` plus
`lib/smalt/egress_router.ex`.

| module | file |
|---|---|
| `Smalt.EgressRouter` | `lib/smalt/egress_router.ex` |
| `Smalt.DataPlane.BlobService` | `lib/smalt/data_plane/blob_service.ex` |
| `Smalt.DataPlane.BlobStorage` | `lib/smalt/data_plane/blob_storage.ex` |
| `Smalt.DataPlane.ConditionalHeaders` | `lib/smalt/data_plane/conditional_headers.ex` |
| `Smalt.DataPlane.Cosmos` | `lib/smalt/data_plane/cosmos.ex` |
| `Smalt.DataPlane.KQL` | `lib/smalt/data_plane/kql.ex` |
| `Smalt.DataPlane.PartitionKey` | `lib/smalt/data_plane/partition_key.ex` |
| `Smalt.DataPlane.KeyVaultActions` | `lib/smalt/data_plane/key_vault_actions.ex` |
| `Smalt.DataPlane.VaultData` | `lib/smalt/data_plane/vault_data.ex` |
| `Smalt.DataPlane.SKR` | `lib/smalt/data_plane/skr.ex` |
| `Smalt.DataPlane.Sentinel` | `lib/smalt/data_plane/sentinel.ex` |
| `Smalt.DataPlane.ResourceGraph` | `lib/smalt/data_plane/resource_graph.ex` |
| `Smalt.DataPlane.Purview` | `lib/smalt/data_plane/purview_atlas.ex` |

## Config keys

Derived from `get_env(:smalt, ...)` call sites in `egress_router.ex` and
`lib/smalt/data_plane/`; defaults from `config/config.exs` and call-site
defaults.

| key | default | call site |
|---|---|---|
| `:blob_catch_all_hosts` | `[]` | `config/config.exs` |
| `:skr_allow_legacy_header` | `false` | `config/config.exs` |
| `:kv_master_secret` | `nil` (dev keys generated) | `config/config.exs` |
| `:cosmos_master_key` | nil (dev default) | `egress_router.ex` |
| `:cosmos_ru_limit` | `:infinity` | `data_plane/cosmos.ex` |
| `:sentinel_forensic` | unset (falsy) | `data_plane/sentinel.ex` |
| `:sentinel_dcr_strict` | unset (falsy) | `data_plane/sentinel.ex` |
| `:rg_token_preserve_options` | unset (falsy) | `data_plane/resource_graph.ex` |
| `:eventgrid_response_mode` | unset | `egress_router.ex` |
| `:egress_cors_origins` | `["*"]` | `egress_router.ex` |
| `:egress_port` | `8443` | `lib/smalt/application.ex:167` |

## Refusal vocabulary (egress surface)

Generated from `docs/ERROR_CODES.md` `egress` / `egress-auth` rows:

- 400: ATLAS-400-00-001, BadRequest, InvalidApiVersion, InvalidBody,
  InvalidCloudEvent, InvalidEventGridEvent, InvalidInput, InvalidParameter,
  InvalidQueryParameter, InvalidRequestBody, InvalidXmlOrJson,
  MissingXMsVersion, NotImplemented, SubRequestCountExceedsLimit,
  UnsupportedKeyType
- 401: AuthenticationFailed, InvalidAuthenticationToken,
  InvalidAuthenticationTokenAudience, InvalidAuthenticationTokenIssuer
- 403: AuthorizationFailure, AuthorizationPermissionMismatch
- 404: BlobNotFound, ContainerNotFound, ImmutabilityPolicyNotFound,
  KeyNotFound, KvNotFound, LegalHoldNotFound, NotFound, RouteNotFound,
  SecretNotFound, TransactionNotFound
- 409: ContainerAlreadyExists, ContainerLocked, WriteConflict
- 412: PreconditionFailed
- 413: RequestBodyTooLarge
- 415: UnsupportedMediaType
- 416: InvalidRange
- 5xx: 500 BlobResponseEncodeFailure / InternalError,
  501 NotImplemented, 503 RouteNotReady

Auth-mode refusal: `:enforce` (default) refuses unsigned requests;
`config :smalt, :auth_mode, :enforce` in `config/config.exs:20`, audiences
`:token_audiences` (`https://management.azure.com`).

## KD cross-links

Canonical register: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — the table
is ground truth; every divergence named here names its row.

Blob:
- KD-01 `comp=metadata` 201 vs 200
- KD-02 `comp=list` XML RFC-1123
- KD-03 container props last-modified format
- KD-04 400 InvalidQueryParameter vs InvalidQueryParameterValue
- KD-05 container DELETE mis-route
- KD-52 block-commit corruption (Put Block List)
- KD-60 `comp` mis-dispatch CLASS (generic splat arms)
- KD-61 blob batch missing
- KD-62 user delegation key + SAS-only URIs
- KD-66 ranged-GET content-md5/crc64 ignored
- KD-67 x-ms-version value never validated
- KD-92 ARM-container vs data-plane container store split

Cosmos:
- KD-06 query whitelist
- KD-07 ReadFeed bare array
- KD-08 max-item-count ignored
- KD-09 container list no continuation
- KD-36 TS upsert 409
- KD-44 TS bulk 400
- KD-63 change feed absent
- KD-64 Patch (RFC 6902) unrouted
- KD-65 sprocs/triggers/UDFs unrouted
- KD-93 query feed stale projection
- KD-94 cosmos AAD Authorization shape

KV / SKR / Sentinel / ResourceGraph:
- KD-10..KD-17 KV route/crypto holes (create, update, rotation,
  delete/purge, verify misalign, versioned crypto, release policy)
- KD-33 kid placement nit
- KD-34 api-version percent-encoding
- KD-75 updateKey (PUT /keys/{name}) absent
- KD-22 Sentinel KQL project_columns regex leak
- KD-23 ResourceGraph normalize_pipeline mixed form

## See Also

- `docs/ERROR_CODES.md` (generated; `just gen-error-codes`)
- `docs/reference/kd-register.md`
- `docs/reference/ets-tables.md`