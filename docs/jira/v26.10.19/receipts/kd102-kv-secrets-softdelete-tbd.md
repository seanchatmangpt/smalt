# kd102-kv-secrets-softdelete-tbd.md — KD-102 witness (lane, 2026-10-19)

- **KD row**: KD-102 (KV secrets no soft-delete)
- **Standing**: PASS-EVIDENCED (wire behavior witnessed this session; register row flip is registrar's call)
- **Close condition**: add secret soft-delete/recover/purge routes or typed UNSUPPORTED; falsifier: SDK delete → recoverable via getDeletedSecret/recoverDeletedSecret
- **Falsifier status**: CONFIRMED OPEN — delete is hard; `deletedSecrets` listing is RouteNotFound (transcript below)

## Evidence

Substrate: `scripts/substrate-ctl up --block b6 --auth enforce` → ports
amqp=39060 eh=39061 arm=39062 egress=39063 tls=39064 mcp=39065, auth=enforce.
Bearer minted from the emulator STS:

```
$ curl -s -X POST "http://localhost:39062/contoso/oauth2/v2.0/token" \
    -d 'grant_type=client_credentials&client_id=x&client_secret=y&scope=https://vault.azure.net/.default'
{"access_token":"eyJhbGciOiJSUzI1NiIsImtpZCI6Ikk3RmJnRDl0RGhkRGhJaThwaXg0UmxXZV96ejltRWluemJkdG1HZFg3OFUiLCJ0eXAiOiJKV1QifQ.eyJhcHBpZCI6IjAwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMCIsImF1ZCI6Imh0... (1275 chars)"}
HTTP 200
```

KV probe target: plaintext egress port 39063 (raw curl; raw curl against
plaintext egress is fine for evidence). `$T` = the bearer above.

```
$ E=http://localhost:39063

=== create ===
$ curl -s -w '\nHTTP %{http_code}\n' -X PUT "$E/secrets/wf-kd102?api-version=7.4" \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
    -d '{"value":"kd102-secret-value"}'
{"attributes":{"created":1792430802,"enabled":true,"updated":1792430802},"id":"https://localhost:8443/secrets/wf-kd102/3140","value":"kd102-secret-value"}
HTTP 200

=== delete ===
$ curl -s -w '\nHTTP %{http_code}\n' -X DELETE "$E/secrets/wf-kd102?api-version=7.4" -H "Authorization: Bearer $T"
{"attributes":{"created":1792430802,"enabled":true,"updated":1792430802},"id":"https://localhost:8443/secrets/wf-kd102/3140"}
HTTP 200

=== get after delete ===
$ curl -s -w '\nHTTP %{http_code}\n' "$E/secrets/wf-kd102?api-version=7.4" -H "Authorization: Bearer $T"
{"error":{"code":"SecretNotFound"}}
HTTP 404

=== GET /deletedsecrets (documented absence — the gap itself) ===
$ curl -s -w '\nHTTP %{http_code}\n' "$E/deletedsecrets?api-version=7.4" -H "Authorization: Bearer $T"
{"error":{"code":"RouteNotFound","message":"No route matches GET /deletedsecrets"}}
HTTP 404
```

## Reading

Delete is a hard delete: GET after DELETE returns `SecretNotFound` 404 and
there is no soft-delete plane — `GET /deletedsecrets` is unserved
(`RouteNotFound`, not an empty list and not a typed UNSUPPORTED). The
close condition (soft-delete/recover/purge routes or typed UNSUPPORTED)
remains open.

Context: solo (lane witness run, block b6, auth=enforce)
