# GAP RECEIPT — Azure App Configuration data plane absent from smalt substrate

> **STALE-RECEIPT ANNOTATION (2026-10-17):** the MISSING verdict below is
> superseded. The /kv family landed in `lib/smalt/egress_router.ex:884-897`
> (list/PUT/GET/DELETE with etag CAS + If-Match-required delete; KD-COVERS:
> KD-53). Witness receipt: `receipts/cap-appconfig-kv.md`; probe receipts
> `sdk-results/ts-appconfig.md` + `sdk-results/py-appconfig.md` (16/16 PASS
> each, exit 0). Body preserved verbatim below — do not amend further.



- **Standing**: CONFIRMED (gap confirmed by live probe, 2026-10-16, lane 527 Agent 7)
- **Subject**: smalt egress data plane (port 8443), App Configuration surface
- **Verdict**: **MISSING** — no `/appconfig`, `/kv`, or `/configuration/kv` route family
  exists in `lib/smalt/egress_router.ex` or `lib/smalt/registry.ex`
  (case-insensitive grep for appconfig/app-configuration over both files: zero matches).
- **Falsifier of the gap itself**: an authed `GET /kv?api-version=1.0` against 8443
  returning 200 with a kv document closes this gap.

## Live probe receipts (2026-10-16, substrate live on 8443/9443, enforce auth mode)

Tokenless (enforce-mode Bearer gate fires before routing):

```
$ curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/appconfig   # → 401
$ curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/kv          # → 401
$ curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/secrets     # → 401
```

Authed (HS256 token minted via `POST /{tenant}/oauth2/v2.0/token` on ARM 9443,
641-char access_token received):

```
/appconfig        404 {"error":{"code":"RouteNotFound","message":"No route matches GET /appconfig"}}
/appconfig/kv     400 {"error":{"code":"MissingXMsVersion","message":"Missing required x-ms-version header, SAS token, or allowlisted host."}}
/kv               404 {"error":{"code":"RouteNotFound","message":"No route matches GET /kv"}}
/configuration/kv 400 {"error":{"code":"MissingXMsVersion","message":"Missing required x-ms-version header, SAS token, or allowlisted host."}}
```

`/appconfig/kv` and `/configuration/kv` fall into the blob splat route family
(x-ms-version gate) — the probe witnesses they are NOT App Config routes either.

## Azure App Configuration wire contract (what the console client implements)

REST surface `https://{host}/kv`, `api-version=1.0`:

- **kv CRUD**: `GET/PUT/DELETE /kv/{key}?label={label}&api-version=1.0`
- **List**: `GET /kv?key={prefix}&label={label}&api-version=1.0`; continuation via the
  `Sync-Token` response header (cache-coherence token across instances).
- **ETag conditionals**: `If-Match` on PUT/DELETE (exact etag = CAS, `*` = any;
  mismatch → **412**); `If-None-Match` on GET (match → **304**) and on PUT
  (`If-None-Match: *` = create-only; existing → **412**).
- **409** on unconditional overwrite of an existing kv (write conflict).
- **Labels**: isolated namespaces within a key (`dev`, `prod`); get/list filter by label.
- **Feature flags** are kv entries with content type
  `application/vnd.microsoft.appconfig.kv+json;ctype-feature`; value is JSON
  `{id, enabled, conditions: {client_filters: [{name, parameters}]}}`. Evaluation
  filters (client-side): `Microsoft.Percentage`, `Microsoft.TimeWindow`,
  `Microsoft.Targeting`, `AlwaysOn` alias; unknown filter → fail-closed false.

## Missing substrate routes (enumerated)

| Route | Method | Contract | Status |
|---|---|---|---|
| `/kv` | GET | list with `key`/`label` filters | MISSING |
| `/kv/{key}` | GET | read one (`label` param; `If-None-Match` → 304) | MISSING |
| `/kv/{key}` | PUT | write one (`If-Match` CAS / `If-None-Match: *` create-only; 412/409 verdicts) | MISSING |
| `/kv/{key}` | DELETE | delete one (`If-Match`, idempotent 404) | MISSING |
| labels | — | label dimension on every kv route | MISSING |
| `Sync-Token` header | — | multi-instance cache coherence | MISSING |
| feature-flag content type | — | opaque to substrate (kv value + contentType passthrough) | MISSING (client-side concern) |

## Minimal substrate route proposal (follows the proven /secrets pattern)

`lib/smalt/egress_router.ex` already carries the Key Vault **/secrets** data plane
(lane 345, v26.10.16, `egress_router.ex:738-805`): `put "/secrets/:name"` stores into
the `:smalt_vault_secrets` ETS via `Store.put` and returns a typed record with
`id`/`value`/`etag`. The App Config plane is the same shape plus a label dimension.

Minimal route family (`/kv` plane, `:smalt_appconfig_kv` ETS table):

1. `get "/kv"` — list with `key` prefix + `label` filters → `{"items": [...]}`.
2. `get "/kv/:key"` — read; `If-None-Match` match → 304; absent → typed 404.
3. `put "/kv/:key"` — `If-Match` CAS (412 stale), `If-None-Match: *` create-only (412),
   unconditional overwrite of existing → 409; stores `{key, label, value, contentType,
   etag, last_modified}` via `Store.put(:smalt_appconfig_kv, {key, label}, record)`.
4. `delete "/kv/:key"` — `If-Match` (default `*`), idempotent 404.
5. Feature flags need NO substrate logic — they are kv entries; the console client
   parses/evaluates them (implemented + tested, see below).
6. `Sync-Token` response header = max(last_modified) across rows (single-VM substrate:
   one ETS is the authority).

Effort estimate: one lane, mostly mechanical — the /secrets handler family is the
template; the only new semantics are the label dimension and the 412/409
conditional-write verdicts.

## Client coverage (this lane)

`workspace/lib/azure/appconfig.ts` + `workspace/test/appconfig_features.test.ts`.

Test receipt (verbatim summary, `node --test workspace/test/appconfig_features.test.ts`,
Node v26.10.0, 2026-10-16):

```
✔ parseFeatureFlag parses a valid flag with filters
✔ parseFeatureFlag rejects non-flag payloads loudly
✔ isFeatureFlagContentType matches the Azure wire content type only
✔ evaluate: enabled with no filters is true; disabled is false
✔ evaluate: Percentage filter buckets deterministically on userId
✔ evaluate: TimeWindow filter honors Start/End
✔ evaluate: Targeting filter matches audience users
✔ evaluate: unknown filter is fail-closed false; Any/All requirement types
✔ contract: put creates, get round-trips, etag present
✔ contract: unconditional overwrite of existing kv is 409
✔ contract: If-Match CAS update succeeds; stale etag is 412
✔ contract: create-only If-None-Match:* refuses duplicates with 412
✔ contract: labels isolate values; list filters by key prefix + label
✔ contract: feature flags ride the wire content type and parse back
✔ contract: watchSentinel fires on etag change and is stoppable
✔ contract: DELETE with If-Match removes; 404 delete is idempotent
﹣ substrate: typed RouteNotFound for GET /kv (gap witness) # SKIP-LOUD substrate-pending (see below)
ℹ tests 17 / pass 16 / fail 0 / skipped 1 / exit 0
```

The single skip is the honest-skip tier-3 probe: tokenless enforce-mode auth returns
401 before routing; the authed surface has no App Config routes (witnessed 404
RouteNotFound above). A skip is a loud skip, never a faked pass.

## Close condition

Re-probe command (post-landing falsifier):

```bash
TOK=$(curl -s -X POST "http://127.0.0.1:9443/00000000-0000-0000-0000-000000000000/oauth2/v2.0/token" \
  -d "client_id=probe&client_secret=x&grant_type=client_credentials&scope=https://smalt/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -s -H "Authorization: Bearer $TOK" "http://127.0.0.1:8443/kv?api-version=1.0"
# expect 200 {"items":[]} — that 200 IS the gap-closing falsifier
```

When the route family lands in `lib/smalt/egress_router.ex`, tag the edit with
`# KD-COVERS: KD-<n>` (KD row minted from this receipt);
`scripts/kd_flip.py --apply` flips the row only on a witness receipt postdating
the lib mtime.
