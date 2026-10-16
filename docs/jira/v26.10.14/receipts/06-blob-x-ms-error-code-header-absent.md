# Receipt — GAP(blob-x-ms-error-code-header-absent) CLOSED (lane 06)

- **Status:** CLOSED (landed) — for lane 13 consumption.
- **Surface:** all blob-plane error responses (`Smalt.EgressRouter`).

## What landed

- `blob_error/3` now puts `x-ms-error-code: <code>` extracted from the JSON
  body's code slot — handles `%{"error" => %{"code" => code}}` (the
  `not_found_error/1` shape) and flat `%{"code" => code}` bodies; bodies with
  no binary code slot (e.g. `%{"error" => inspect(other)}`) emit no header.
- `blob_error_xml/4` (comp=list XML envelope) sets the same header
  unconditionally.
- JSON envelope bodies are unchanged — additive header only.

## Witness

```
mix test test/data_plane/blob_hardening_test.exs → 91+ tests incl.:
  "blob comp=list junk maxresults -> 400 XML envelope + x-ms-error-code header"
  "non-list blob errors keep JSON envelope but gain x-ms-error-code header"
→ 0 failures
mix test test/wire/egress_wire_test.exs test/data_plane/cosmos_test.exs \
  test/data_plane/key_vault_actions_test.exs test/data_plane/audit_planes_test.exs \
  test/security/security_hardening_test.exs → 288 tests, 0 failures
```

Header precedent: real Azure Blob carries the error code in both the envelope
and `x-ms-error-code`; previously zero hits for the header name across `lib/`
and `test/` (re-derived 2026-10-15, docs-corpus-lens-9).
