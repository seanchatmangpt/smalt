# r13 — T-11: Azure Functions resource type + admin management API + host.json validation

- window: v26.10.28 · ticket: `tickets/T11-functions-resource-and-admin-api.md` · date: 2026-10-29
- tier: beam (`test/integration/functions_test.exs`) · status: **CODE-COMPLETE (r13), awaiting integration run**

## landed

1. **ARM `Microsoft.Web/sites` (kind `functionapp`), registry pattern**: sites
   live as ONE ARM-shaped row per site in `:smalt_resources`, key = downcased
   full ARM id (`/providers/` segment included — the generic ARM convention,
   same as the SB namespace parent rows). PUT is a real ARM upsert (first
   PUT 201, re-PUT 200 with the merge path preserving engine-owned state —
   a re-PUT never wipes app settings, host.json or keys). GET/LIST (rg +
   subscription faces, `{"value": [...]}`), DELETE 200 -> 404. The wire
   render (`Functions.public_site/1`) drops the engine-reserved properties,
   so a plain site GET carries exactly the real shape (`id` / `name` /
   `type` / `kind` / `location` / `properties.state Running` /
   `properties.hostNames` / `defaultHostName`). Engine state rides INSIDE
   `properties` under reserved keys (`appSettings`, `hostJson`, `hostKeys`,
   `functionKeys`, `functions`, `hostId`), stripped from user-supplied PUT
   properties too (no forgery). Registry-pattern consequence: the gateway's
   existing RG-delete cascade and generic `:smalt_resources` inventory
   consumers (resource graph, export template) see sites rows like any
   other resource — no shadow copy.
2. **`config/appSettings` CRUD (StringDictionary)**: PUT/GET
   `.../sites/:name/config/appSettings` with the real sub-resource shape
   (`Microsoft.Web/sites/config`, flat `properties` name/value map —
   exactly what `az functionapp config appsettings set` wraps and what
   `az ... list` renders as name/value/slotSetting client-side). PUT is the
   wholesale-replace semantics of the real Update Application Settings API
   (`az set` does read-merge-write client-side). Typed 404 on unknown
   sites; typed 400 on a non-string-map body.
3. **`listFunctionKeys`-class actions**: `POST .../sites/:name/listHostKeys`
   (real HostKeys shape: `masterKey` / `functionKeys` / `systemKeys`,
   minted at site create; 32-byte base64url keys like real Azure) and
   `POST .../sites/:name/functions/:fn/listFunctionKeys` (StringDictionary
   `{"default": ...}`; typed 404 for a never-published function, never a
   fabricated key). `POST /admin/host/keys` renews a host-level function
   key (the master key stays fixed, as in real Azure).
4. **SCM-lite admin management API (site host surface)**: `GET
   /admin/host/status` (real `id`/`state`/`version` shape — `state:
   "Running"` is what tooling health checks parse), `GET/POST
   /admin/host/keys`, `GET /admin/functions` (real array-of-function-
   records shape: `name` / `status` / `config` / `function{enabled,config}`),
   `GET /admin/functions/:name`, and `POST /admin/functions/:name` ->
   typed refusal. The site is resolved from the request the way Core Tools
   resolves it: the Host header (`<name>.azurewebsites.net`, or
   `scm.<name>.azurewebsites.net`), with an explicit `?sitename=<name>`
   override for single-host dev; unresolvable -> typed 404 `SiteNotFound`,
   unknown site -> typed 404. No api-version required on `/admin/*` (the
   real host admin API carries none).
5. **host.json parse + validation at the sync/publish PUT** (`POST/PUT
   /admin/host/synctriggers`, envelope `{"hostJson": <json text or decoded
   object>, "functions": [{"name", "config"}]}`): the three malformed
   classes refuse typed 400 with the portal-style validation error —
   `InvalidHostJson` ("Unable to parse 'host.json' as JSON: ..."),
   `UnknownHostJsonExtension` ("Unknown extension 'x' found in 'host.json'.
   Please update the extension bundle version or remove the entry."),
   `InvalidHostJsonVersion` ("The 'version' property in 'host.json' must be
   set to '2.0' or higher, found '1.0'."); a missing `version` refuses too
   (the real Functions host treats that as schema v1). Top-level allowlist
   per ticket scope: `version`, `functionTimeout`, `extensions`,
   `extensionBundle`, `logging`, `concurrency` (nested extension keys like
   `extensions.http` are NOT policed). Fail-closed: a refused sync stores
   NOTHING (no host.json, no function records). A successful sync stores
   the decoded host.json and upserts the function records, minting the
   `default` function key once per NEW function.
6. **Invocation is OUT, honestly** (ticket scope 4): both invocation faces —
   the ARM `POST .../sites/:name/functions/:fn/invocations` and the admin
   `POST /admin/functions/:name` — answer the typed, CONSTANT 400
   `FunctionRuntimeNotEmulated` (`Functions.invocation_refused/0`), never a
   fake 200: smalt provisions and configures function apps but runs no
   function host runtime.

File scope (all new, nothing else touched — `arm_gateway/router.ex` itself,
`application.ex`, `parity/` OFF; the mount is the integrator patch below):

- `lib/smalt/data_plane/functions.ex` — engine: site records
  (create/update/delete/get/list + find-by-name), `set_app_settings/2`,
  `validate_host_json/1` + typed variant, `host_keys/1`,
  `function_keys/2`, `sync_triggers/3`, `invocation_refused/0`.
- `lib/smalt/arm_gateway/providers/functions_router.ex` — pass-through Plug
  (`@behaviour Plug` like `EventGrid.PushRouterPlug`): claims
  `Microsoft.Web/sites[...]` (case-insensitive on `resourceGroups` /
  `Microsoft.Web` / `sites`) + `/admin/...`, passes EVERYTHING else through
  with the conn untouched, and HALTS only on routes it answered (so
  `plug(:match)`/`plug(:dispatch)` never double-dispatch). Once it claims
  the sites prefix it ANSWERS — unknown sub-actions get typed 404s instead
  of falling into the generic `:provider_ns/:resource_type` face, which
  would otherwise store a junk resource row for a Functions action it
  cannot interpret. The one carve-out: nested provider faces
  (`.../sites/:name/providers/...` — metrics, tags, locks,
  availabilityStatuses) pass through UNCHANGED so the gateway's existing
  generic handlers keep ownership (no regression for those lanes).

## wiring (integrator applies) — EXACT patch

Mount in `lib/smalt/arm_gateway/router.ex` immediately BEFORE `plug(:match)`
(current lines 72–78):

```diff
--- a/lib/smalt/arm_gateway/router.ex
+++ b/lib/smalt/arm_gateway/router.ex
@@ -72,7 +72,13 @@
   plug(:arm_request_id)
   plug(:arm_throttle)
   # AZURE-FIDELITY lane 18: control-plane throttling realism — DEFAULT-OFF
   # (rate/burst nil). Gate-off the plug passes the conn through untouched.
   plug(Smalt.Egress.ThrottlePlug)
+  # T-11 (r13): Microsoft.Web/sites (kind functionapp) ARM face + SCM-lite
+  # admin surface. Mounted BEFORE :match so the sites routes never reach the
+  # generic :provider_ns/:resource_type face; the router passes unmatched
+  # conns through untouched and HALTS only on routes it answered.
+  plug(Smalt.ArmGateway.Providers.FunctionsRouter)
   plug(:match)
   plug(:dispatch)
```

## court

`Smalt.Internal.FunctionsTest` (`test/integration/functions_test.exs`) —
in-process gateway dispatch exactly like `sb_arm_rules_test.exs`
(`Smalt.ArmGateway.Router.call`, Plug.Test, real `:smalt_resources` rows,
auth riding the gateway chain's `:anonymous` test mode; no mocks) — 7 tests:

1. ARM PUT site creates 201 (fresh per-run name -> deterministic create
   face) -> GET shape echo (`kind functionapp`, `properties.state Running`,
   `defaultHostName`, engine keys absent from the wire) -> idempotent
   re-PUT 200.
2. `config/appSettings` PUT -> GET round-trips the settings map
   (StringDictionary sub-resource shape); typed 404 on an unknown site.
3. synctriggers with a VALID host.json -> 200 (`hostJsonValidated` true,
   functions published) -> `GET /admin/functions` array shape + single
   function GET + `FunctionNotFound` for a ghost + `/admin/host/status`
   shape (`state "Running"`, binary id/version). The engine face itself is
   also asserted (`validate_host_json/1 == :ok`).
4. host.json malformed JSON / unknown top-level extension / `version`
   1.0 -> typed 400s (`InvalidHostJson` / `UnknownHostJsonExtension` /
   `InvalidHostJsonVersion`, portal-style messages) + fail-closed witness
   (the refused sync's marker function was never published).
5. `/admin/host/keys` real shape (masterKey/functionKeys/systemKeys) ->
   POST renew (`cli-key`) visible in a subsequent GET -> `listHostKeys`
   face returns the same keys under `{"properties": ...}` ->
   `listFunctionKeys` for a synced function (its `default` key) and typed
   404 for a ghost.
6. Invocation endpoints (ARM `.../functions/:fn/invocations` AND admin
   `POST /admin/functions/:fn`) answer the typed
   `FunctionRuntimeNotEmulated` refusal.
7. ARM DELETE -> 200 -> GET 404 (config/appSettings gone with the site).

**Not yet executed** — the r13 lane is code-only per the compile-freeze SLA
(no mix/test/git in this pass); the court runs with the next integration
pass and this receipt + the ticket stamp say so. NOTE: the court dispatches
through `Smalt.ArmGateway.Router` on purpose — it IS the wiring witness:
without the integrator patch above, every route here 404s through the
gateway catch-all, which is the failure you would see.

## DoD mapping (the Azure developer's view)

- "`az functionapp create --name myfn` provisions a site your
  `az functionapp list` shows with the same id/name/state shapes as Azure"
  = court test 1. The wire body nests `properties.state` exactly like the
  real ARM response; az flattens `properties` client-side — so against
  smalt, exactly as against Azure, `az functionapp list`/`show` surfaces
  `"state": "Running"` plus the same `id`/`name`.
- "`az functionapp config appsettings set` round-trips your settings" =
  court test 2 (az wraps the StringDictionary `properties` map; smalt
  stores/serves the same flat map byte-for-byte).
- "tooling that calls the admin API gets the JSON it parses in production,
  including host keys" = court tests 3 + 5 (`/admin/host/status`,
  `/admin/functions[...]`, `/admin/host/keys`, listHostKeys/
  listFunctionKeys faces).
- "a host.json with a bad extension version gives the typed validation
  error Azure's portal shows" = court test 4.
- "the invoke URL returns an honest typed 'runtime not emulated' error
  instead of a fake 200" = court test 6.

## notes

- **Sync envelope divergence (documented)**: real Core Tools publishes
  `host.json` inside the zipdeploy zip and calls `POST /admin/host/synctriggers`
  with function metadata. smalt's sync face carries hostJson as a FIELD of
  the sync body because zip payload storage is a ticket non-goal ("no
  deployment/zipdeploy beyond storing site state"). The validation contract
  (typed 400s, portal-style messages) is the part the DoD pins, and it is
  enforced on the face Core Tools touches.
- **api-version posture**: `Microsoft.Web` is not yet a Registry-admitted
  namespace (ProviderMatrix projects Registry rows; the ticket's evidence
  section notes the GAP). On the claimed faces this router therefore only
  REQUIRES `api-version` (gateway-identical envelope + message:
  `MissingApiVersionParameter`) and does not strict-validate it — the
  gateway's own default permissive posture (KD-78). Strict validation can
  ride a later lane once Microsoft.Web lands in the registry/provider
  matrix (also what `az` probes via provider registration; T-02
  pre-seeding territory).
- **Known simplification**: the sites PUT face does not require the parent
  resource group row to exist (real ARM does; `az functionapp create`
  creates the RG first, so the real flow never observes the difference).
- The ARM sites faces inherit the gateway plug chain (CORS, x-ms-request-id
  echo, Bearer — `:anonymous` in the test env, throttling default-off);
  the `/admin/*` surface sits behind the same Bearer plug by design (the
  real SCM face is ARM-token protected too).
