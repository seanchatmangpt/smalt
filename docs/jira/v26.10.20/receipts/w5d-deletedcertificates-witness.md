# W5D — deletedcertificates twin-family completion witness (ERRC wave-5, lane w5d)

**Standing:** **ALIVE** (witnessed execution on the exact running subject, both legs)

Owner lane: w5d (exclusive: `lib/smalt/egress_router.ex`, certificates twin-family only).
Scope: GET /deletedcertificates, GET /deletedcertificates/:name, POST .../recover (+ purge parity).

## Finding

w4g already landed the full deletedcertificates surface — routes at
`lib/smalt/egress_router.ex:1269-1296` (list / get / recover / purge) plus
`Smalt.DataPlane.Certificates` `list_deleted/0`, `get_deleted/1`, `recover/1`,
`purge/1`, `delete/1` (`lib/smalt/data_plane/certificates.ex`). The w2a note
("GET/recover still 404 inside egress") is STALE. Net diff required from w5d: **zero**.

## Witness (real curl, lane b12 enforce, substrate pid 67268, 2026-10-20)

Both legs. Sequence create → delete → get-deleted 200 → list-deleted 200 (+name present) →
recover 200 → get 200 → re-delete → purge 204 → get-deleted-after-purge 404.

```
=== LEG 8443 (http://127.0.0.1:8443, enforce bearer) ===
-- create                    201
-- delete (soft)             200
-- get live (expect 404)     404
-- get-deleted (expect 200)  200
-- list-deleted (expect 200) 200
name-in-list: true
-- recover (expect 200)      200
-- get live after recover    200
-- re-delete for purge leg   200
-- purge (expect 204)        204
-- get-deleted after purge   404

=== LEG 9444 (https://127.0.0.1:9444, TLS twin, SSL_CERT_FILE=.smalt/tls/ca-cert.pem) ===
(identical — 201/200/404/200/200/name-in-list:true/200/200/200/204/404)
```

Script: /tmp/w5d_witness.sh; subject names `w5d-dc-6196-*` / `w5d-dc-25106-*`.
Semantic note: purge 204 requires the deleted bundle, so the Azure-correct order is
recover → get 200 → re-delete → purge 204. A purge directly after recover 404s
(deleted row already restored) — this is correct Azure parity, not a defect.

## Gates

- `MIX_BUILD_ROOT=_build-lane-w5d mix compile --warnings-as-errors` → green ("Generated smalt app")
- `MIX_BUILD_ROOT=_build-lane-w5d mix test test/internal/certificates_pending_test.exs` → 2 tests, 0 failures
- `MIX_BUILD_ROOT=_build-lane-w5d mix test test/integration/certificates_kd104_witness_test.exs` → 2 tests, 0 failures
- Full internal tier at witness time: 48 tests, 5 failures — ALL 5 belong to the concurrent
  cosmos analytical-TTL lane's in-flight files (`CosmosAnalyticalTtlTest` x2 + 3 census
  allowlist rows for their new files). Not w5d scope; zero edits made by w5d.

Context: full (substrate up, both legs, real transport).
