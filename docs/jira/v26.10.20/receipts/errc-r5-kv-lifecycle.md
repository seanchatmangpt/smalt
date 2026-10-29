# ERRC-R5 — Key Vault secret full-lifecycle walk (popcorn_demo LiveKV)

**Standing:** **ALIVE** — real REST lifecycle witnessed on the live substrate
before and after the module existed.

## Surface

- `popcorn_demo/lib/popcorn_demo/live_kv.ex` (new) — `PopcornDemo.LiveKV.run/0`
- `popcorn_demo/test/live_kv_test.exs` (new) — 4 Chicago tests, real wire only

## REST face (curl before module existed, 2026-10-20)

- KD-15 challenge handshake witnessed: tokenless
  `GET http://127.0.0.1:8443/secrets/popcorn-probe?api-version=7.4` →
  **401** with
  `www-authenticate: Bearer authorization="http://127.0.0.1:9443/organizations", resource="http://127.0.0.1:8443", error="invalid_token", error_description="MissingBearerToken"`
  (raw header, unmodified). Data plane 8443 is plain HTTP (TLS reset via
  https; the TLS twin is 9444 per repo convention).
- Token: `POST http://127.0.0.1:9443/organizations/oauth2/v2.0/token`
  (grant_type=client_credentials, any client_id/secret — enforce mode) → 200,
  1290-byte RS256 bearer.
- Set Secret: `PUT /secrets/popcorn-secret?api-version=7.4`
  `{"value":"popcorn-<epoch>-<rand>"}` → **200**
- Get Secret: `GET /secrets/popcorn-secret?api-version=7.4` → **200**, value
  byte-equal (`BYTE_EQUAL len=24` from the curl probe).
- Delete Secret: `DELETE ...` → **200**; re-GET → **404**
  `{"error":{"code":"SecretNotFound"}}`.

## run/0 receipt (direct execution, live substrate)

```
receipt: {:ok, "kv=OK(popcorn-secret:30-bytes-lifecycle)"}
```

## Chicago test (real substrate, real :gen_tcp sockets, no mocks)

```
Finished in 0.05 seconds (0.00s async, 0.05s sync)
Result: 4 passed
```

- challenge probe asserts a real 401 + `www-authenticate:` naming
  `http://127.0.0.1:9443` (raw socket, tokenless)
- full lifecycle: set → get byte-equal → delete → 404 SecretNotFound
- repeatable (2 consecutive runs OK)
- typed outcomes

## Execution notes (disclosed)

- Test env: elixir 1.20.4-otp-29, `MIX_BUILD_ROOT=_build-errc-r5`. Plain
  `mix test test/live_kv_test.exs` is currently BLOCKED by a PRE-EXISTING
  broken sibling file `popcorn_demo/lib/popcorn_demo/live_rules.ex` (another
  lane's in-flight file: `defend` delimiter, then undefined `req/3` after the
  delimiter fix) — I applied the delimiter unblock (disclosed per SLA) and
  stopped there; the lane's tests were run by compiling only lane-owned
  files against the `_build-errc-r5/test` dep ebins
  (`elixir -pa _build-errc-r5/test/lib/jason/ebin --eval 'Code.compile_file(...)'`).
  Not wired into application.ex.
- Transport is real HTTP/1.1 over `:gen_tcp` (loopback-only), keeping response
  HEADERS so the handshake consumes `www-authenticate`.
