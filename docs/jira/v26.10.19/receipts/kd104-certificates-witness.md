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
