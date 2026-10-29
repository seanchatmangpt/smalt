# T-04 — App Configuration: Key Vault references + Event Grid change notifications

- status: CODE-COMPLETE (2026-10-29): r7, awaiting integration run
- window: v26.10.28 · maps-to: Topaz v1.11 "App Configuration — Key Vault references · EventGrid change notifications" (snapshots already ahead) · verdict-at-open: **PARTIAL**
- size: **M** · depends-on: — · parity-leg: appconfig/eg suite

## current state (evidence)

Snapshots are ahead: `lib/smalt/data_plane/appconfig_snapshots.ex` + MCP
tools `appconfig.snapshots.kv`/`appconfig.snapshots.list`. The `/kv` plane
supports PUT/GET with If-Match races (receipted in
`verification/ts/wf2/index.ts`). Missing: the Key Vault reference
content-type contract and kv-write → Event Grid events (the existing SB
bridge fires on ARM ResourceWriteSuccess only, not kv-plane writes).

## scope

1. **KV references**: store and return values with content-type
   `application/vnd.microsoft.appconfig.keyvaultref+json` byte-identically
   (the reference body shape `{"uri":"<vault-secret-id>"}`), including in
   snapshots and revisions listing. (Resolution stays client-side — real
   Azure's SDK and configuration providers resolve; the service must not
   diverge by resolving server-side.)
2. **Change notifications**: on kv PUT/DELETE, emit
   `AppConfigurationKeyValueModified` / `…Deleted` events into the mounted
   Event Grid surface (system-topic shaped), deliverable to event
   subscriptions and the webhook receiver with the real event schema
   (`data.key`, `data.etag`, `data.label`).

## non-goals

- Server-side secret resolution (would diverge from real Azure).
- Feature-flag/`*.featureflag` content-type semantics (separate follow-up).

## Definition of Done — the Azure developer's view

You store a Key Vault reference with the
`application/vnd.microsoft.appconfig.keyvaultref+json` content type using
`@azure/app-configuration`, then read it back (and list revisions) — the
reference comes back with the same uri and content type, and your
`AzureAppConfigurationKeyVaultReference`-aware code resolves it against
smalt's Key Vault exactly as it would in Azure. In a second terminal you
have an Event Grid subscription on your config store's system topic; the
moment your app writes a key, your webhook receives
`AppConfigurationKeyValueModified` with the key, etag and label of the
change — same schema the Azure Functions App Configuration trigger parses.

## receipts required

kv-ref round-trip receipt (content-type + revisions); webhook capture of
Modified/Deleted events; snapshot containing the reference.
