# KD-104 witness — Certificates surface (lane c5)

Standing: PASS (witness green, compile green)
Context: solo
Subject: `lib/smalt/data_plane/certificates.ex` @ lane build `_build-lane-c5`
Date: 2026-10-19

## What landed

- `lib/smalt/data_plane/certificates` — completed from the lost-lane PARTIAL
  (kept, not restarted). Real self-signed X.509 v3 mint via OTP `:public_key`
  (RSA-2048, sha256WithRSAEncryption, integer serial, DER-encoded OPENTYPE
  NULL params), heir'd ETS `:smalt_vault_certificates`, create (201, atomic
  409 on existing) / get (200) / list / delete→purge (typed 404) + `pem/1`
  export.
- `test/internal/certificates_kd104_witness_test.exs` — module-level witness.

## Command + output

```
$ MIX_BUILD_ROOT=_build-lane-c5 mix test test/internal/certificates_kd104_witness_test.exs
..
Finished in 0.2 seconds (0.00s async, 0.1s sync)
2 tests, 0 failures
EXIT=0
```

## Falsifier satisfied (Chicago, no mocks)

Subject CN and validity are read back through `:public_key.der_decode/2`
off the *stored* DER (created==fetched asserted), PEM re-decodes to the
byte-identical DER, list contains the row, delete→get→purge are typed 404
(`CertificateNotFound`), duplicate create is typed 409
(`CertificateNameAlreadyExists`) with the first row surviving intact.

## Lane disclosures

- Compile-freeze SLA unblock (disclosed): `lib/smalt/data_plane/vault_data.ex`
  had an unclosed `@doc` heredoc mid-edit; closed the delimiter (`"""` before
  `def vault_secret_names`). No semantic change intended.
- Subsequent freezes (kql.ex, purview_atlas.ex, event_hubs.ex,
  management_rpc.ex) were fixed by their owners inside the SLA window; I
  bounded-retried rather than touching them.
- Router is owned elsewhere: route-patch lines delivered in the lane report,
  not applied to `lib/smalt/egress_router.ex`.

## KD-104 close condition

KD-104 close = CertificateClient SDK probe (next wave, once routes wire).
This witness does NOT flip the KD-104 register row.

---

# KD-104 live-wire witness — wave-2 ERRC lane (2026-10-20)

Standing: SUSPECT (falsifier FAILS at the persistence leg; KD-104 row must NOT flip)
Context: solo
Subject: live substrate `just substrate-up` (pid 67992), `lib/smalt/egress_router.ex`
routes @ main 1217df8 + integration, `lib/smalt/data_plane/certificates.ex`
Date: 2026-10-20
Prior appendix: lane c5 module witness above (PASS, in-process)

## Environment

- `@azure/keyvault-certificates` NOT in `verification/ts/node_modules/@azure`
  (only keyvault-keys) → falsifier run as raw wire mirroring the SDK request
  shapes, per lane order.
- Auth: `:enforce`. STS token minted
  `POST http://127.0.0.1:9443/smalt-emulator-tenant/oauth2/v2.0/token`
  (client_credentials, client_id `smalt-emulator-client`) → 1311-char JWT.
- KV surface answered on plain-http **8443**. Note: the TLS twin 9444
  (the leg real Azure SDKs require — they refuse Bearer over http) answers
  `404 RouteNotFound` for `/certificates/*` (see step 7): the certificates
  routes are wired on the egress router only, not the twin. Surface is
  unreachable by an actual CertificateClient today.

## Live-wire transcript (all output verbatim)

Routes confirmed wired: `egress_router.ex:1217-1249` (`post
/certificates/:name/create`, `get /certificates`, `get /certificates/:name`,
`delete /certificates/:name`, `post /deletedcertificates/:name/purge`).

```
=== 1. POST /certificates/kd104-witness/create (policy CN=kd104-witness) ===
HTTP 201  — real X.509 minted: {"cer":"MIICvTCCAaWgAwIBAgIR...","id":
"https://127.0.0.1:8443/certificates/kd104-witness","name":"kd104-witness",
"policy":{...,"x509_props":{"subject":"CN=kd104-witness","validity_months":12}},
"attributes":{"created":1792484682,...,"recoveryLevel":"Purgeable"}}

=== 2. GET /certificates/kd104-witness/pending (SDK operation poll shape) ===
HTTP 400 {"error":{"code":"MissingXMsVersion",...}}   (blob splat fallthrough;
  module doc pins create as atomic, never :pending — no LRO surface. Recorded
  per lane order: implementation answers synchronously.)

=== 3. GET /certificates/kd104-witness ===
HTTP 404 {"error":{"code":"CertificateNotFound",...}}   <-- FAIL: row written
  by step 1 is gone from the same beam (single listener pid 67992 on 8443).

=== 4. GET /certificates (list) ===
HTTP 200 {"value":[]}   <-- FAIL: empty immediately after create.

=== dup. POST create same name (~30s later) ===
HTTP 201 with a NEW cert (subject CN=dup-probe)   <-- FAIL: typed 409
  CertificateNameAlreadyExists contract broken across requests.

=== 5. DELETE /certificates/kd104-witness ===
HTTP 404 CertificateNotFound (row already lost)

=== 6. POST /deletedcertificates/kd104-witness/purge ===
HTTP 404 CertificateNotFound

=== 7. POST https://127.0.0.1:9444/certificates/tls-twin-probe/create ===
HTTP 404 RouteNotFound  (TLS twin does not proxy the certificates routes —
  CertificateClient-shaped clients cannot reach the surface)

=== 8. final GET /certificates ===
HTTP 200 {"value":[]}
```

The openssl anti-tautology leg could not run: step 3 returns 404, so no
stored DER is retrievable over the wire to parse. (The in-process lane-c5
witness DID parse the DER via `:public_key.der_decode` — mint quality is not
in question; persistence is.)

## Root cause (mechanism, consistent with all 8 observations)

`Smalt.DataPlane.Certificates.ensure_table/0` lazily calls `start_link/1`
from the **request process**. The GenServer is therefore linked to the
short-lived Plug request process; when the request exits after the response,
the owner (and its `heir: self()` ETS table) dies with it. Every new request
recreates an empty table → create 201, get 404, list empty, no 409.

Isolated in-process repro (`mix run /tmp/kd104_repro.exs`: create in a
spawned short-lived process, then get from the evaluator) could not be
landed: the shared tree was in compile-freeze for the whole window
(sentinel.ex → arm_gateway/router.ex → key_vault_actions.ex → cosmos_sql.ex,
successive other-lane in-flight edits; bounded retries ~18 min). The wire
transcript above is the evidence of record. A repair lane should re-derive
the repro after the freeze lifts.

## Required repair (for the owner lane; not applied — no code-edit ownership)

Supervise the table owner: add the Certificates GenServer to the smalt
supervision tree (as the `/keys` + `/secrets` siblings do) or have
`ensure_table/0` start it under a permanent child spec, so owner lifetime is
decoupled from request processes.

## KD-104 register disposition

- Falsifier does NOT run green → **do not `kd_flip` KD-104**. Row stays open
  (witness = SUSPECT for the wire face).
- Two defects for the repair lane: (1) table persistence/lifetime above;
  (2) TLS twin 9444 does not route `/certificates/*`, so the SDK-required
  TLS leg is unreachable even after (1) is fixed.
- kd_flip rides the registrar pass only after a green re-witness.

---

# KD-104 wire-fix re-witness — wave-2 repair lane w2q (2026-10-20)

Standing: ALIVE (falsifier GREEN on both legs; row is registrar's to flip via kd_flip)
Context: solo
Subject: `lib/smalt/data_plane/certificates.ex` + `lib/smalt/application.ex`
(TlsTwinDispatch egress prefixes) @ lane build `_build-lane-w2q`
Prior appendices: lane c5 module witness (PASS); wave-2 SUSPECT appendix above

## Fixes landed (both defects from the SUSPECT appendix)

1. **Table lifetime** — `ensure_table/0` no longer starts a request-linked
   owner GenServer. Converted to the shadow-table law pattern (identical to
   `Smalt.Policy.ensure_tables/0` and `cosmos.ex ru_table/0`): the ETS table
   `:smalt_vault_certificates` is created lazily from the request process with
   `{:heir, Process.whereis(:init), []}` (node-permanent) + `rescue ArgumentError`
   for the create race. The GenServer was deleted outright: the table is
   `:public`, so `:ets.insert_new/2` is atomic from any process — the
   GenServer.call serialization hop was pure defect surface.
2. **TLS twin** — `/certificates` added to `TlsTwinDispatch` `@egress_prefixes`
   (`lib/smalt/application.ex`, same mechanism as the w2a `/deletedkeys` line);
   header comment updated.
3. **(found during re-witness) UTCTime year encoding** — `asn1_time/1` encoded a
   4-digit year into a `utcTime` (RFC 5280 UTCTime is 2-digit year); openssl
   answered `notBefore=Bad time value`. Now: y >= 2050 -> generalizedTime
   (4-digit), else utcTime with `rem(y, 100)` (2-digit).

## Command + output (verbatim)

```
$ python3 /tmp/kd104_wire_fix_witness.py   # STS :enforce token (1311-char JWT),
                                           # b9 falsifier, both legs
CREATE -> 201        (both legs)
DUP    -> 409 {"error":{"code":"CertificateNameAlreadyExists",...}}   (both legs)
GET    -> 200        (both legs)
OPENSSL: subject=CN=kd104-fix-witness
notBefore=Oct 20 08:58:22 2026 GMT
notAfter=Oct 20 08:58:22 2027 GMT       (both legs — "Bad time value" gone)
LIST   -> 200 count=1 has_row=True     (both legs)
DELETE -> 200;  GET-after-del -> 404 CertificateNotFound;  PURGE -> 404  (both legs)
PERSIST cross-check: list on 8443 -> 200
WITNESS_VERDICT=PASS name=kd104-fix-16079
EXIT=0
```

Legs: `http://127.0.0.1:8443` AND `https://127.0.0.1:9444` (TLS twin,
`--cacert .smalt/tls/ca-cert.pem`) — the SDK-required TLS leg from the SUSPECT
appendix step 7 (`404 RouteNotFound`) is answered: the twin now proxies
`/certificates/*` to EgressRouter.

```
$ MIX_BUILD_ROOT=_build-lane-w2q mix test test/integration/certificates_kd104_witness_test.exs
Finished in 0.2 seconds (0.00s async, 0.2s sync)
2 tests, 0 failures
EXIT=0

$ MIX_BUILD_ROOT=_build-lane-w2q mix test test/internal --exclude test:/arm_consumer_group_bridge_test/
Finished in 2.1 seconds (0.1s async, 2.0s sync)
27 tests, 0 failures
```

## Lane disclosures

- Exclusion disclosed: `test/internal/arm_consumer_group_bridge_test.exs` is
  lane w2j's in-flight file (untracked, not mine) — mid-window it was a
  compile-abort (MismatchedDelimiterError, ~10 min freeze), post-SLA-recovery
  it fails 5 InternalTier.CensusTest rows + the population fence, ALL citing
  only that file. Internal tier excluding it: 27/0 green; `vm_zero_growth_test`
  green in isolation. No certificates-owned failure anywhere.
- Compile-freeze SLA unblocks applied to other lanes' files: NONE (all freezes
  self-resolved by their owners; I bounded-retried).
- A concurrent reformat of `certificates.ex` (heir option reordered in the
  `:ets.new` list, semantics identical) landed mid-window alongside my edits;
  final content re-read and verified.
- The mid-session wire 400s were my own broken intermediate build (the
  5-directive io_lib format bug above) still serving from a stale beam —
  root-caused, fixed, and superseded by the transcript above; NOT another
  lane's regression.

## KD-104 register disposition

Falsifier GREEN on both legs (in-process integration witness + live wire over
8443 and the 9444 TLS twin). KD-104 is ready to flip — the flip rides the
registrar pass (`scripts/kd_flip.py --apply`), gated on this receipt postdating
the shim, per the standing KD law. This lane does not flip the register.
