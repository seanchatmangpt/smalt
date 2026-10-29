# KD-126 live sign witness — W13-C (2026-10-20)

**Standing:** PASS (fix landed, EC sign/verify live-witnessed; ES384/32B now typed 400 InvalidParameter, was 500)

Context: solo

## Defect (as dispatched)

KD-126's EC arm (jwk_for_kty/4, `# KD-COVERS: KD-126`) passed its plug-conn
court but `POST /keys/:name/sign` with ES256 was reported 500 on the live
substrate.

## Diagnosis (live reproduction, substrate pid 1835, pre-fix boot)

- ES256 create 200 + ES256 sign 200 + verify value:true + tampered value:false
  all reproduced GREEN on the pre-fix boot with well-formed 32-byte digests.
- The 500 reproduces deterministically on the SAME unguarded seam: ES384 sign
  over a P-384 key with a 32-byte (SHA-256) digest.

## Root cause (file:line)

`lib/smalt/data_plane/key_vault_actions.ex:1639` (pre-fix) — `do_sign/3` EC arm
calls `:crypto.sign(:ecdsa, curve.md, {:digest, digest}, ...)` with no rescue.
Erlang crypto raises `{:badarg, {~c"pkey.c",338}, ~c"Bad binary size for the
algorithm"}` when the wire digest length does not match the curve's hash
(ES384 over 32 bytes), the exception escapes `kv_crypto_dispatch` ->
`safe_dispatch` -> uncaught -> **500**.

The EC create arm (`lib/smalt/egress/KvRoutes.ex` jwk_for_kty/4) was NOT at
fault; the key_material cache shape/name were correct end to end.

## Diff (surgical)

`lib/smalt/data_plane/key_vault_actions.ex`, `do_sign/3` EC arm only: the
crypto call + JWS flatten wrapped in try/rescue `ErlangError | ArgumentError`
-> typed `{:error, 400, InvalidParameter, "digest size N bytes does not match
<alg> over <crv>"}` (the Azure client-fault face), mirroring do_verify's
existing guarded boolean. No other arm touched.

Note (lane disclosure): the dispatched ownership list named
`lib/smalt/egress/KvRoutes.ex`, but the seam is in `key_vault_actions.ex`;
the fix landed there instead (single site, 16 lines).

## Test

`test/integration/kv_ec_create_test.exs` + one test: "ES384 over a 32-byte
digest answers 400 InvalidParameter, not 500" (observable behavior changed).

```
scripts/fast_test.sh test/integration/kv_ec_create_test.exs
5 tests, 0 failures
```

(Plain `mix test <file>` currently fails at application boot with a
Supervisor FunctionClauseError on ANY test file, incl. unrelated ones —
pre-existing harness condition on this machine, not session-introduced;
fast_test.sh is the working gate.)

## Live witness (post-fix substrate, pid 62236, boot POSTDATES the fix)

KD-15 handshake via scripts/dev_env.sh STS token on the 9444 TLS twin:

1. ES256 create: **200**
2. ES256 sign (32B digest): **200**
3. ES256 verify same digest/sig: **200, "value": true**
4. tampered signature: **200, "value": false**
5. P-384 create: **200**
6. ES384 sign, 48B digest: **200**
7. ES384 sign, 32B digest (the pre-fix 500): **400 InvalidParameter
   "digest size 32 bytes does not match ES384 over P-384"** (was 500)
8. ES384 alg vs P-256 key: **400 InvalidAlgorithm** (gate before crypto, unchanged)

Substrate cycled via `just substrate-down` / `just substrate-up` (flock-managed,
lock fd closed by substrate.sh; ports 9443/9444/5672/5673 all UP, lock FREE
after).

Falsifier for the flip: any repeat of the 500 on the live sign surface, or
`mix compile` regression. Coordinator may flip KD-126 on this receipt.
