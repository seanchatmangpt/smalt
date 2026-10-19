# kd104-kv-certificates-tbd.md — KD-104 witness (lane, 2026-10-19)

- **KD row**: KD-104 (KV certificates absent)
- **Standing**: PASS-EVIDENCED (wire behavior witnessed this session; register row flip is registrar's call)
- **Close condition**: add certificate routes or typed UNSUPPORTED; falsifier: CertificateClient create/get succeeds
- **Falsifier status**: CONFIRMED OPEN — `certificates/*` unserved (transcripts below)

## Evidence

Same substrate session as kd102 (block b6, auth=enforce, egress 39063).
`$T` = Bearer token.

```
=== PUT certificate (first attempt, no x-ms-version header) ===
$ curl -s -w '\nHTTP %{http_code}\n' -X PUT "$E/certificates/wf-kd104?api-version=7.4" \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
    -d '{"policy":{"key_props":{"exportable":true,"kty":"RSA"}}}'
{"error":{"code":"MissingXMsVersion","message":"Missing required x-ms-version header, SAS token, or allowlisted host."}}
HTTP 400

=== PUT certificate (retry with x-ms-version header) ===
$ curl -s -w '\nHTTP %{http_code}\n' -X PUT "$E/certificates/wf-kd104?api-version=7.4" \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
    -H 'x-ms-version: 2021-12-02' \
    -d '{"policy":{"key_props":{"exportable":true,"kty":"RSA"}}}'
{"error":{"code":"NotFound","message":"PUT /certificates/wf-kd104 is not implemented on this plane (reserved namespace 'certificates'); nothing was stored."}}
HTTP 404

=== GET certificate ===
$ curl -s -w '\nHTTP %{http_code}\n' "$E/certificates/wf-kd104?api-version=7.4" \
    -H "Authorization: Bearer $T" -H 'x-ms-version: 2021-12-02'
{"error":{"code":"NotFound","message":"GET /certificates/wf-kd104 is not implemented on this plane (reserved namespace 'certificates'); nothing was stored."}}
HTTP 404
```

## Reading

The certificate plane is absent: both PUT and GET under
`/certificates/*` answer typed 404 "not implemented (reserved namespace
'certificates')" — a reserved-namespace refusal, not a certificate
resource. Close condition (certificate routes or typed UNSUPPORTED)
open. Note: without the `x-ms-version` header the egress router answers
`MissingXMsVersion` 400 before the namespace refusal.

Context: solo (lane witness run, block b6, auth=enforce)
