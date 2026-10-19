# kd109-appconfig-feature-flags-tbd.md — evidence receipt (kd-lane, 2026-10-19)

- **KD row**: KD-109 (appconfig feature-flag passthrough)
- **Standing**: PASS-EVIDENCED (opaque passthrough confirmed; no typed flag-record endpoint)
- **Context**: solo

## Witness

Substrate: block b3, ARM 39032, egress (KV plane) 39033, auth enforce. Bearer minted at
`POST /organizations/oauth2/v2.0/token` (client_credentials, any id/secret accepted).
KV follows the KD-15 challenge posture — tokenless first:

```
$ curl -s -D - -X PUT "http://127.0.0.1:39033/kv/wf-kd109" -H "Content-Type: application/vnd.azure.appconfig.featureflag+json" -d '{"id":"wf-kd109",...}'
HTTP/1.1 401 Unauthorized
www-authenticate: Bearer authorization="http://127.0.0.1:39032/organizations", resource="http://127.0.0.1:39033", error="invalid_token", error_description="MissingBearerToken"
```

### PUT feature flag via App Config envelope

```
$ curl -s -D - -X PUT "http://127.0.0.1:39033/kv/wf-kd109" -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" -H "If-Match: *" \
    -d '{"value":"{\"id\":\"wf-kd109\",\"enabled\":true,\"conditions\":{\"client_filters\":[]}}","contentType":"application/vnd.azure.appconfig.featureflag+json"}'
HTTP/1.1 200 OK
content-type: application/json; charset=utf-8

{"contentType":"application/vnd.azure.appconfig.featureflag+json","etag":"\"41E3FB2E...\"","key":"wf-kd109","label":"","last_modified":1792431217,"value":"{\"id\":\"wf-kd109\",\"enabled\":true,\"conditions\":{\"client_filters\":[]}}"}
```

### GET back — value echoed verbatim, no typed flag shape

```
$ curl -s -D - -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:39033/kv/wf-kd109"
HTTP/1.1 200 OK
etag: "41E3FB2E490605E66BACFE45F4BA0CE47F6C6612310FE20CD060A2585DA90E0F"

{"contentType":"application/vnd.azure.appconfig.featureflag+json","etag":"\"41E3FB2E...\"","key":"wf-kd109","label":"","last_modified":1792431217,"value":"{\"id\":\"wf-kd109\",\"enabled\":true,\"conditions\":{\"client_filters\":[]}}"}
```

Value is the raw JSON string echoed verbatim; `contentType` round-trips as an opaque
string. There is no typed flag record: no parsed/enabled/selector shape, no flag-specific
query surface.

### Typed flag-record endpoint probe → not a flag endpoint

```
$ curl -s -D - -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:39033/kv/.appconfig.featureflag/wf-kd109"
HTTP/1.1 400 Bad Request
x-ms-error-code: MissingXMsVersion
{"error":{"code":"MissingXMsVersion","message":"Missing required x-ms-version header, SAS token, or allowlisted host."}}

$ curl -s -D - -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:39033/.appconfig.featureflag/wf-kd109?api-version=1.0"
HTTP/1.1 400 Bad Request
x-ms-error-code: MissingXMsVersion
```

Both flag-style paths fall through to the storage-plane version gate — no App Config
feature-flag record surface exists. Matches source: `lib/smalt/egress_router.ex:1199`
("Feature-flag content type is an opaque passthrough (client-side evaluation concern)").

## Side finding (raw-body PUT)

A PUT sending the bare flag JSON (not the `{"value":...,"contentType":...}` envelope) with
`Content-Type: application/vnd.azure.appconfig.featureflag+json` answers `201` and stores
`value: null, contentType: null` — the plane ignores the request Content-Type entirely and
reads only the envelope body. Real Azure App Configuration would store the body as the
value. Recorded for the registrar; not repaired (lane scope: evidence only).

## Falsifier status

Skeleton falsifier ("SDK roundtrip with typed shape recognized") is REFUTED as stated —
the observed behavior is the registered divergence itself: opaque passthrough, no typed
shape. KD-109 row semantics (passthrough divergence) match the evidence; close condition
belong to the registrar.
