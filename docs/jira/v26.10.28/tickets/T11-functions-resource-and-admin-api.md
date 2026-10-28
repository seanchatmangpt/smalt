# T-11 — Azure Functions: resource type + admin management API + host.json validation

- window: v26.10.28 · maps-to: Topaz v1.13 "Azure Functions — Function App resource · admin API · host.json" · verdict-at-open: **GAP**
- size: **M** · depends-on: — (T-01 integration optional)

## current state (evidence)

No `Microsoft.Web/sites` provider in `lib/` (map row; verified — no
Functions surface in the 13-provider ARM route set).

## scope

1. ARM `Microsoft.Web/sites` (kind `functionapp`) + `config`
   (appSettings) CRUD via the registry pattern; `listFunctionKeys`-class
   actions where the real SDK expects them.
2. Admin management API on the site host surface (the SCM/Kudu-lite
   routes Core Tools touch): `/admin/host/status`, `/admin/host/keys`,
   `/admin/functions` (list) and `/admin/functions/<name>` (keys) with the
   real JSON shapes.
3. `host.json` parse + validation at sync/publish time: unknown top-level
   extensions, malformed JSON, and version inconsistencies refuse with
   typed 400s (the real extension-bundle validation errors).
4. Simulated function invocation is OUT (no runtime; invocation endpoints
   answer typed not-supported).

## non-goals

- Running function code (no host runtime; the design law again).
- Deployment/zipdeploy of code payloads beyond storing site state.

## Definition of Done — the Azure developer's view

`az functionapp create --name myfn` against smalt provisions a site your
`az functionapp list` shows with the same id/name/state shapes as Azure,
and `az functionapp config appsettings set` round-trips your settings.
Your tooling that calls the admin API — `func azure functionapp list`
style flows, or your own `/admin/host/status` health check — gets the
JSON it parses in production, including host keys. Uploading a
`host.json` with a bad extension version gives you the same typed
validation error Azure's portal shows. Calling the function's invoke URL
returns an honest typed "runtime not emulated" error instead of a fake
200.

## receipts required

ARM CRUD + appSettings court; admin-API shape receipt (status/keys);
host.json validation court (valid + 3 malformed classes).
