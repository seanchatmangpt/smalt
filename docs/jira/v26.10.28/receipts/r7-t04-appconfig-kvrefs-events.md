# r7 — T-04: App Configuration keyvaultref contract + kv Event Grid events

- window: v26.10.28 · ticket: `tickets/T04-appconfig-kvrefs-and-change-events.md` · date: 2026-10-29
- tier: beam (`test/integration/appconfig_events_test.exs`) · status: **CODE-COMPLETE (r7), awaiting integration run**

## landed

1. **KV references (no server-side resolution)**: the `/kv` plane stores and
   returns the Key Vault reference content type
   `application/vnd.microsoft.appconfig.keyvaultref+json` verbatim — the
   record map (key/label/value/contentType/etag/last_modified) round-trips
   byte-identically through PUT → GET → list (`public_kv_record/1` is the
   identity render, unchanged). The reference body
   `{"uri":"<vault-secret-id>"}` is opaque passthrough: resolution stays
   client-side (`@azure/app-configuration` +
   `AzureAppConfigurationKeyVaultReference`-aware providers), exactly like
   real Azure — the service must not diverge by resolving server-side.
2. **Change notifications**: PUT `/kv/:key` (create or modify) publishes
   `AppConfigurationKeyValueModified` and DELETE publishes
   `AppConfigurationKeyValueDeleted` into the Event Grid engine under topic
   `appconfig` (`Smalt.Messaging.EventGrid.publish/2` — at-least-once,
   id-deduped). Event shape mirrors the real App Configuration system-topic
   schema: `%{id: uuid-v4, eventType, subject, eventTime: iso8601, data:
   %{key, label, etag}}` — subject is the bare key, suffixed `|<label>` only
   when a non-empty label is set. Fire-and-forget law: the publish is
   try/rescue-wrapped (`require Logger` at the module head); an event-engine
   failure logs and never fails the kv write itself. Precondition failures
   (412/409) and missing-kv deletes publish nothing.

File scope: `lib/smalt/egress_router.ex` touched ONLY inside the `/kv`
section — two hook lines (PUT success path after `kv_write/4`, DELETE
success path after `Store.delete/2`) plus the private helpers
`publish_kv_change/2`, `kv_change_event/3`, `kv_event_uuid/0` near
`kv_write`. Nothing else in the router restructured.

## court

`Smalt.Internal.AppconfigEventsTest` (in-process egress dispatch like
`sb_arm_rules_test.exs` / `parity_lane_wire_test.exs`; real `:smalt_appconfig`
Store rows; real Event Grid engine via `EventGrid.subscribe("appconfig",
name, self())` + `assert_received`; non-tokenless Authorization header to
satisfy the /kv challenge guard under the test env's `:anonymous` mode) — 4
tests:

1. keyvaultref PUT → GET → list: value string and content type byte-identical,
   etag stable (DoD "same uri and content type"; no server-side resolution).
2. create → Modified with the record's key/label/etag; If-Match modify →
   second Modified with the NEW etag and a fresh event id.
3. If-Match delete → Deleted carrying the deleted record's etag; post-delete
   GET 404; `refute_received` witnesses nothing else published.
4. labeled kv → `key|label` subject + label in `data`.

**Not yet executed** — the r7 lane is code-only per the compile-freeze SLA
(no mix/test/git in this pass); the court runs with the next integration
pass and this receipt + the ticket stamp say so.

## notes

- **Webhook delivery** rides the existing `EventGridWebhookPlug`
  (`Smalt.EventGridWebhook`, `/eventgrid/hooks/:subscriber` receiver face) —
  unchanged this ticket. Topic `appconfig` subscribers receive
  `{:event_grid, "appconfig", name, id, event}` in-process with the same
  schema the Azure Functions App Configuration trigger parses on
  `eventType`; push-to-remote remains the documented air-gap divergence.
- **Snapshots unchanged** (already ahead per the ticket's evidence section):
  kv-ref rows surface in `appconfig.snapshots.*` with the contentType
  verbatim since the snapshot engine reads the same `:smalt_appconfig`
  records.
- DoD mapping: "store a Key Vault reference, read it back (and list revisions)
  with the same uri and content type" = court test 1; "the moment your app
  writes a key, your webhook receives AppConfigurationKeyValueModified with
  the key, etag and label" = court tests 2–4. Feature-flag content-type
  semantics stay out (ticket non-goal).
