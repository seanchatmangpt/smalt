# kd103-kv-secrets-backup-restore-tbd.md — KD-103 witness (lane, 2026-10-19)

- **KD row**: KD-103 (KV secrets backup/restore refusals)
- **Standing**: PASS-EVIDENCED (wire behavior witnessed this session; register row flip is registrar's call)
- **Close condition**: implement secret backup blob roundtrip or typed UNSUPPORTED; falsifier: backup → restore roundtrip succeeds
- **Falsifier status**: CONFIRMED OPEN — backup and restore both refuse with typed errors (transcripts below)

## Evidence

Same substrate session as kd102 (block b6, auth=enforce, egress 39063;
bearer from STS on arm 39062). `$T` = Bearer token.

```
=== backup (no body, secret wf-kd102 exists/deleted state per KD-102 transcript) ===
$ curl -s -w '\nHTTP %{http_code}\n' -X POST "$E/secrets/wf-kd102/backup?api-version=7.4" \
    -H "Authorization: Bearer $T"
{"error":{"code":"NotImplemented","message":"POST /secrets/wf-kd102/backup (backup) is not implemented on the /secrets plane; nothing was stored."}}
HTTP 501

=== restore (first attempt, no x-ms-version header) ===
$ curl -s -w '\nHTTP %{http_code}\n' -X POST "$E/secrets/restore?api-version=7.4" \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
    -d '{"value":{"value":"kd102-secret-value"}}'
{"error":{"code":"MissingXMsVersion","message":"Missing required x-ms-version header, SAS token, or allowlisted host."}}
HTTP 400

=== restore (retry with x-ms-version header) ===
$ curl -s -w '\nHTTP %{http_code}\n' -X POST "$E/secrets/restore?api-version=7.4" \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
    -H 'x-ms-version: 2021-12-02' -d '{"value":"eyJ2YWx1ZSI6ImtkMTAyIn0="}'
{"error":{"code":"NotFound","message":"POST /secrets/restore is not implemented on this plane (reserved namespace 'secrets'); nothing was stored."}}
HTTP 404
```

## Reading

`backupSecret` gets a typed `NotImplemented` 501, not a backup blob.
`restoreSecret` gets a typed 404 "not implemented (reserved namespace)"
once the egress version gate is satisfied; without the `x-ms-version`
header the egress router answers `MissingXMsVersion` 400 first. No
backup/restore roundtrip exists — close condition open.

Context: solo (lane witness run, block b6, auth=enforce)
