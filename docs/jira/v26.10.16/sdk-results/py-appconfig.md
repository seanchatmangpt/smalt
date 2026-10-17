# PY App Configuration Probe — /kv wire surface (KD-53)

Standing: **PASS** — 16/16 PASS, exit 0, against the shared substrate
(enforce auth; bearer minted from the STS at POST
`/{tenant}/oauth2/v2.0/token` on ARM :9443; /kv probed on egress :8443;
venv `test/sdk-python/.venv-arm`).

## Subject

- Probe: `/Users/sac/smalt/test/sdk-python/py_appconfig.py`
- Surface: `GET /kv`, `PUT /kv/:key?label=`, `GET /kv/:key?label=`,
  `DELETE /kv/:key?label=` served by `lib/smalt/egress_router.ex:924-1054`
  (KD-COVERS: KD-53)
- SDK: `azure-appconfiguration` is not installed in the lane venv; the probe
  rides plain REST (the same wire the SDK would drive), following the
  py_arm_resources.py STS-token convention.

## Command

```bash
cd /Users/sac/smalt && test/sdk-python/.venv-arm/bin/python test/sdk-python/py_appconfig.py; echo "exit=$?"
```

## Output (receipted run, 2026-10-17)

```
[PASS] auth tokenless GET /kv -> 401 challenge :: status=401
[PASS] PUT create -> 201, quoted etag, payload round-trips :: status=201 body={"contentType":"text/plain","etag":"\"196FF3C83381B7E4F03ED1ABF402E4780529AEFF2D65D0670EF4A3DCEDB6790D\"","key":"pyprobe-1792270233-k1","label":"probe","last_modified":1792270233,"value":"v1"}
[PASS] GET -> 200, value round-trips, etag header == PUT etag :: status=200 etag="196FF3C83381B7E4F03ED1ABF402E4780529AEFF2D65D0670EF4A3DCEDB6790D"
[PASS] list key= prefix filter returns run's items :: status=200 items=["pyprobe-1792270233-k1", "pyprobe-1792270233-k2", "pyprobe-1792270233-k3"]
[PASS] list label=other filter returns exactly one item :: status=200 items=["pyprobe-1792270233-k3"]
[PASS] list response carries sync-token header :: sync-token=smalt-1792270233
[PASS] stale If-Match PUT -> 412 :: status=412 body={"error":{"code":"PreconditionFailed","message":"If-Match precondition failed for kv pyprobe-1792270233-k1 (label probe)
[PASS] If-Match fresh etag overwrite -> 200, etag rotated :: status=200
[PASS] create-only If-None-Match:* on existing -> 412 :: status=412
[PASS] headerless overwrite of existing -> 409 WriteConflict :: status=409 body={"error":{"code":"WriteConflict","message":"kv pyprobe-1792270233-k1 (label probe) exists; supply If-Match to overwrite
[PASS] DELETE without If-Match -> 409 MissingIfMatch :: status=409 body={"code":"MissingIfMatch","message":"If-Match header must be specified for the delete operation"}
[PASS] DELETE stale If-Match -> 412 :: status=412
[PASS] DELETE If-Match:* -> 204 :: status=204
[PASS] post-delete GET/DELETE -> 404 KvNotFound :: GET=404 DELETE=404
[PASS] PUT If-Match:* on absent kv -> 412 (RFC 7232) :: status=412
[PASS] DELETE with exact current etag -> 204 :: status=204

appconfig py probe: 16/16 PASS
exit=0
```

## Verdict

Zero failing rows, zero divergences. The /kv wire contract is CONFORMANT from
the Python lane as probed: same create/CAS/precondition/delete semantics as
the TS receipt (ts-appconfig.md), same 409 MissingIfMatch on headerless
DELETE, same 404 KvNotFound idempotence.
