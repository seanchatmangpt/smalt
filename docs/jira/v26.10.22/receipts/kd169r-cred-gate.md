# Receipt — KD-169R: Web PubSub server-face credential gate (KD-169 close)

**Standing**: ALIVE
**Context**: solo
**Date**: 2026-10-22
**Lane**: KD-169R (repo `/Users/sac/smalt`, canonical checkout, build root `_build-kd169r`)

## What landed

KD-169 close condition satisfied: the Web PubSub server API faces
(`generateToken` / `negotiate` / `groups :send`) in
`lib/smalt/webpubsub/router.ex` now require the connection-string access
key on the `Authorization` header, two accepted forms:

* `Bearer <jwt>` — HS256 signed with the access key, `aud` bound to
  `https://<host header>`, live `exp` (the form real Azure server SDKs
  mint per request).
* `SharedAccessKey <key>` — raw access key, `Plug.Crypto.secure_compare`
  constant-time compare (loopback dev convenience form).

Missing / wrong-key / wrong-aud / expired / wrong-scheme all answer a
typed 401 JSON naming the face (`{"error": ..., "face": "generateToken" |
"negotiate" | "groups:send"}`). The client WS upgrade face is UNCHANGED —
client connections still ride the minted client JWTs
(`Smalt.WebPubSub.Token.verify/2`, EXPL-4 F1 fail-closed semantics), no
server credential needed on `GET /webpubsub/hubs/:hub?access_token=`.

Access-key source: the same `:web_pubsub_access_key` application env
(default `smalt-wps-dev-access-key`) that `Smalt.WebPubSub.Token` signs
client JWTs with — the connection-string access-key analog; dev-key
override convention `SMALT_WPS_ACCESS_KEY` (cf. `SMALT_SB_SHARED_KEY` in
`scripts/dev_env.sh`). Both tagged `# KD-COVERS: KD-169` in router.ex
(KD-166 tag retained).

## Court (real Bandit wire, no mocks)

`test/internal/kd169r_cred_gate_test.exs` — 8 legs against the app-booted
Bandit face on its real port (`web_pubsub_port`), real :httpc loopback
HTTP, real Joken HS256, raw RFC6455 client handshake leg:

```
$ MIX_BUILD_ROOT=_build-kd169r bash scripts/fast_test.sh test/internal/kd169r_cred_gate_test.exs
..
Finished in 0.1 seconds (0.00s async, 0.1s sync)

Result: 8 passed
[05:09:07] wall: 2s (build root: _build-ft-7c3c981b)
```

Legs: valid Bearer admits generateToken (minted client JWT verifies with
roles round-trip); absent credential 401 naming face; wrong
SharedAccessKey 401 "access key mismatch"; valid SharedAccessKey admits
negotiate (url still carries access_token); wrong-aud Bearer 401; expired
Bearer 401; groups :send 401 absent / 202 valid Bearer / 404 unknown
action under valid cred; client WS upgrade 101 with valid client token
and 401 with bad token (server credential NOT required — client path
unaffected).

## Regression (both suites green)

```
$ MIX_BUILD_ROOT=_build-kd169r bash scripts/fast_test.sh test/internal/webpubsub_test.exs
Result: 7 passed

$ MIX_BUILD_ROOT=_build-kd169r bash scripts/fast_test.sh test/internal/wps_exp4_court_test.exs
Result: 10 passed
```

`webpubsub_test.exs` helpers (`post_json` / `push_wal`) now mint the real
server Bearer JWT per request — the whole client-flow court (join, push,
byte-exact delivery, CloudEvents) runs through the gated faces.

## Register

KD-169 flipped OPEN (registered) -> CLOSED-WITH-EVIDENCE in both
registers via `scripts/kd_flip.py --only KD-169`, receipt postdating the
router fix.

## Compile-freeze disclosure

Lane KD-169R applied a minimal unblock fix to another lane's in-flight
`lib/smalt/attestation/maa.ex` (with/else scope error: `reserved` bound
in the with-chain is not visible in `else`; renamed the else-branch local
to `nonce` derived from the hoisted `runtime_result` — the exact fix the
adjacent comment already described; behavior unchanged, `with`-clause
binding prefixed `_reserved`). Disclosed here for cross-lane
attribution; the owning lane should name it in its own receipt.
