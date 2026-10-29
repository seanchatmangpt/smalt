# KD-131 CBS put-token close witness (shared substrate, canonical ports)

- **Date**: 2026-10-21
- **Lane**: KD131W (bench-runner)
- **Subject**: KD-131 close condition — per-host dev key derived by `scripts/substrate.sh` (dev_env.sh-identical, 44 bytes), CBS put-token 200 on the SHARED plane (canonical ports)
- **Standing**: ALIVE
- **Context**: pair (lane KD131W probing the shared substrate booted by the substrate.sh KD-131 fix, pid 8877)
- **Probe (scratch)**: `/tmp/kd131-cbs-witness.cjs` + `/tmp/kd131-neg.cjs` (scratch, not landed)
- **Falsifier exercised**: KD-131 close condition verbatim — "real CBS put-token 200 on the SHARED plane (canonical ports)"

## Environment

- Substrate UP pre-probe (no restart, per lane orders):
  `bash scripts/substrate.sh status` →
  ```
  [STATUS] port 9443: UP (pid 8877)
  [STATUS] port 9444: UP (pid 8877)
  [STATUS] port 5672: UP (pid 8877)
  [STATUS] port 5673: UP (pid 8877)
  [STATUS] substrate UP (pid 8877)
  [STATUS] lock FREE (flock -n succeeds)
  ```
- Key derivation verified: `node /tmp/kd131-cbs-witness.cjs` leg 0:
  ```
  [env] key bytes=44 prefix=3UKYV3ba...
  ```

## Leg 1 — raw CBS put-token, dev_env-derived per-host key (real rhea 3.x wire)

`node /tmp/kd131-cbs-witness.cjs`:

```
[env] key bytes=44 prefix=3UKYV3ba...
PASS cbs-put-token.status-200 (status=200, audience=sb://127.0.0.1:5672/kd131-cbs-witness)
PASS sdk-send (queue=kd131-sb-witness-1792606596754, output above)
PASS sdk-receive (got 1/1, body-match=true)
```

Raw CBS put-token over the shared 5672 with a SAS token minted from the
dev_env-derived per-host key (`base64(sha256(hostname+"smalt-dev-sb"))`, 44
bytes) answers **200** — not 401 INVALID_LOCAL_SAS. The SasVerifier 32-byte
floor is satisfied and the substrate boot path and the client agree on the
same key with zero exported env (the substrate derived it itself; the probe
derived it via `scripts/dev_env.sh`).

## Leg 2 — @azure/service-bus send/receive (M4 un-skip leg)

Same run, real official SDK (`@azure/service-bus` from
`verification/ts/node_modules`, `AzureNamedKeyCredential` with the per-host
key, connection string `UseDevelopmentEmulator=true` → plaintext AMQP):

```
PASS sdk-send (queue=kd131-sb-witness-1792606596754, payload=kd131-cbs-witness-edd92a730243)
PASS sdk-receive (got 1/1, body-match=true)
```

Send and receive on a fresh queue over the shared plane, key-only auth (no
exported env). The M4 un-skip leg is witnessed green.

## Leg 3 — negative (non-vacuity)

`node /tmp/kd131-neg.cjs`:

```
negative-leg: status=401 description=INVALID_LOCAL_SAS
exit=0
```

The identical CBS put-token shape minted with a WRONG key (all-zero 32-byte
base64) is refused **401 INVALID_LOCAL_SAS** on the same shared plane — the
200 is not vacuous; the verifier is actually checking the signature against
the derived key.

## Verdict

KD-131 close condition **witnessed** on the shared substrate (canonical
ports, pid 8877, no restart): floor-valid 44-byte per-host key, CBS
put-token **200**, official SDK send/receive round trip **1/1 byte-equal**,
wrong-key negative leg **401 INVALID_LOCAL_SAS**. The 401 negative leg
proves the 200 is earned, not vacuous. Standing **ALIVE**.
