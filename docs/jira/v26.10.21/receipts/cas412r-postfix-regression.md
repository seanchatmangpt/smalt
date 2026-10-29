# CAS412R — Post-fix regression pass (recycled OTP-29 beam)

Context: pair(regression witness against the shared recycled beam pid 85369 (reused as-is, never restarted))
**Standing:** PASS

Date: 2026-10-21 · Lane: cas412r · Build root: `_build-cas412r` · Standing: **PASS**

## Subject

- Recycled beam pid **85369** (`beam.smp`, OTP 29 / Elixir 1.20.4-otp-29), auth `:enforce`,
  ports 9443/9444/8443/5672/5673 — reused as-is, not restarted.
- Toolchain pinned via PATH: asdf elixir 1.20.4-otp-29 + erlang 29.1.2 (default PATH elixir
  1.19.5 refused by mix.exs `~> 1.20` — first attempt exited 1 on version gate, rerun clean).

## Census (per-file, `MIX_BUILD_ROOT=_build-cas412r mix test test/integration/<file>`)

| File | Tests | Result |
|---|---|---|
| test/integration/kd155_delete_framing_test.exs | 5 | PASS |
| test/integration/kd156_sb_shape_test.exs | 4 | PASS |
| test/integration/apim_wire_test.exs | 6 | PASS |
| test/integration/appconfig_events_test.exs | 5 | PASS |
| test/integration/kv_crypto_face_test.exs | 4 | PASS |
| test/integration/blob_quota_headers_test.exs | 3 | PASS |
| test/integration/kd_conformance_test.exs | 5 | PASS (CAS 412 If-Match path covered) |
| test/integration/h2_reset_rate_parity_test.exs | 3 | PASS |
| **Total** | **35** | **35 passed, 0 failed, 0 skipped** |

Combined-run cross-check: all eight files in one `mix test` invocation → `Result: 35 passed`.

## Notes

- 412 observed live in kd155 run output (`GET /dbs/kd147db/... Sent 412`) — the CAS/If-Match
  path is exercised on the wire, not just asserted in-process.
- No failures; nothing to type. No fixes applied (regression lane, read-only on lib/).

## Command

```
MIX_BUILD_ROOT=_build-cas412r mix test test/integration/{kd155_delete_framing,kd156_sb_shape,apim_wire,appconfig_events,kv_crypto_face,blob_quota_headers,kd_conformance,h2_reset_rate_parity}_test.exs
# -> Result: 35 passed
```
