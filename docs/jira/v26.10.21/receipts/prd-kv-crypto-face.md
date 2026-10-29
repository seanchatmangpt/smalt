# PRD-KV close: KV REST crypto face witnessed (sign/verify, ES256/RS256 legs)

Context: solo

**Standing:** **ALIVE** (PRD-KV crypto FR extended from "secrets face" to crypto ops,
close condition of the val-prd.md typed-down row met: the KV REST crypto face is
witnessed against the live substrate).

## Claim closed

`docs/jira/v26.10.21/receipts/val-prd.md` PRD-KV row typed crypto ops down to the
POWL-8 HsmSigner with the falsifier: "a KV REST crypto face (POST
/keys/{name}/sign etc.) witnessed 404/absent against the live substrate ... would
extend ALIVE to the crypto FR."

## Finding

The face was implemented and already routed; the sub-claim was a **witness gap**,
not an implementation gap:

- Routes: `lib/smalt/egress/KvRoutes.ex` `kv_crypto_dispatch/4`
  (`post "/keys/:name/:action"` + versioned `post "/keys/:name/:version/:action"`,
  KD-16), api-version 7.4.
- Engine: `lib/smalt/data_plane/key_vault_actions.ex` `sign/3` / `verify/3`
  (`do_sign`/`do_verify`, ES256/ES384 raw r||s JWS form, RS256/PS256, typed
  400 InvalidAlgorithm / 404 KeyNotFound / 200 value:false).
- Wire mechanics REUSE the KD-126 EC arm (`KvRoutes.jwk_for_kty/4` EC branch,
  key_material DER per row); no new lib code was written by this lane.

## Wire witness (live shared substrate, pid 8877, 2026-10-21)

STS challenge dance (POST /{tenant}/oauth2/v2.0/token -> Bearer), data plane
:8443, api-version 7.4:

```
POST /keys/wkvc1/create  {"kty":"EC","crv":"P-256"}
-> 200 {"key":{"kty":"EC","crv":"P-256","x":"3_tD5...","y":"-1Jir...","key_ops":[...,"sign","verify",...]},...}

POST /keys/wkvc1/sign {"alg":"ES256","value":<32B digest b64url>}
-> 200 {"alg":"ES256","kid":"https://127.0.0.1:8443/keys/wkvc1/295746","value":"IxuhGIRr..."}

POST /keys/wkvc1/verify {"alg":"ES256","digest":<digest>,"value":<sig>}
-> 200 {"kid":"...295746","valid":true,"value":true}

wrong digest (bytes 1..32), same sig -> 200 {"valid":false,"value":false}
bad sig "AAA"                     -> 200 {"valid":false,"value":false}
bad alg HS256 (sign)              -> 400 {"error":{"code":"InvalidAlgorithm","message":"unsupported alg HS256"}}
unknown key sign                  -> 404 {"error":{"code":"KeyNotFound"}}
```

## Chicago tests (real curl transport, real STS dance, no mocks)

`test/integration/kv_crypto_face_test.exs` (new, 4 tests): bad alg sign/verify
typed 400 InvalidAlgorithm, unknown key sign/verify typed 404 KeyNotFound.
Plus the existing KD-126 court `test/integration/kv_ec_create_test.exs`
(create -> ES256 sign -> verify true -> tampered false, ES384-over-32B typed 400,
P-384 roundtrip, unknown crv 400).

```
$ MIX_BUILD_ROOT=_build-kvcrypto mix test test/integration/kv_ec_create_test.exs test/integration/kv_crypto_face_test.exs
...
Finished in 0.7 seconds (0.00s async, 0.7s sync)
9 tests, 0 failures
```

## Notes / disclosures

- No `lib/` diff from this lane. The only test-file clause-order bug found
  during authoring (in my own new file) was fixed before green.
- Compile-freeze observation (other lane, disclosed per SLA): first lane test
  runs hit `{:options, {:ciphers, [...]}}` boot abort from a mid-edit
  `lib/smalt/tls.ex` (APIMWIRE AR-SEC-02 surface). The owner lane's charlist
  unblock (already commented in `rsa_ciphers/0`) resolved it; the lane's final
  green run compiles the working tree cleanly. Pre-existing in-flight breakage,
  not session-introduced.

## Standing line

PRD-KV crypto FR: **ALIVE** — KV REST crypto face witnessed (sign/verify, ES256 +
typed refusal legs) over real TLS + STS on the shared substrate; falsifier of the
typed-down row discharged.
