# TS App Configuration Probe — /kv wire surface (KD-53)

Standing: **PASS** — 16/16 PASS, exit 0, against the shared substrate
(enforce auth; bearer minted from the STS at POST
`/{tenant}/oauth2/v2.0/token` on ARM :9443; /kv probed on egress :8443).

## Subject

- Probe: `/Users/sac/smalt/test/sdk-full/appconfig.probe.mjs`
- Surface: `GET /kv`, `PUT /kv/:key?label=`, `GET /kv/:key?label=`,
  `DELETE /kv/:key?label=` served by `lib/smalt/egress_router.ex:924-1054`
  (KD-COVERS: KD-53)
- SDK: `@azure/app-configuration` is not vendored; the probe rides plain REST
  (the same wire the SDK would drive), following the ledger.probe.mjs
  convention.

## Command

```bash
cd /Users/sac/smalt && node test/sdk-full/appconfig.probe.mjs; echo "exit=$?"
```

## Output (receipted run, 2026-10-17)

```
[PASS] auth.tokenless-401 — tokenless GET /kv -> 401 (kv_challenge_guard)
[PASS] put.create-201 — 201, etag="0CEA243B220…, label=probe
[PASS] get.200-etag — 200, value round-trips, etag header == PUT etag
[PASS] list.key-filter — key= prefix filter returned 3 items, all run-prefixed
[PASS] list.label-filter — label=other returned exactly [probe-1792270228112-k3]
[PASS] list.sync-token — sync-token header: smalt-1792270228
[PASS] put.stale-ifmatch-412 — stale If-Match PUT -> 412 "PreconditionFailed"
[PASS] put.cas-overwrite-200 — If-Match fresh etag -> 200, etag rotated
[PASS] put.create-only-412 — If-None-Match:* on existing -> 412 "PreconditionFailed"
[PASS] put.bare-overwrite-409 — headerless overwrite of existing -> 409 "WriteConflict"
[PASS] delete.missing-ifmatch-409 — DELETE without If-Match -> 409 "MissingIfMatch"
[PASS] delete.stale-ifmatch-412 — DELETE stale If-Match -> 412
[PASS] delete.ifmatch-star-204 — DELETE If-Match:* -> 204
[PASS] delete.idempotent-404 — post-delete GET -> 404, second DELETE (If-Match:*) -> 404 KvNotFound=true
[PASS] put.ifmatch-star-create-412 — If-Match:* on absent kv -> 412 (existence assertion, RFC 7232)
[PASS] delete.exact-etag-204 — DELETE with exact current etag -> 204

appconfig probe: 16/16 PASS
exit=0
```

## Verdict

Zero failing rows, zero divergences. The /kv wire contract (create 201, CAS
overwrite 200 with etag rotation, stale If-Match 412, create-only 412,
headerless overwrite 409 WriteConflict, DELETE MissingIfMatch 409 / stale 412
/ star-or-exact-etag 204, post-delete 404 KvNotFound, key=/label= list
filters, sync-token header, tokenless 401 challenge) is CONFORMANT as
probed.
