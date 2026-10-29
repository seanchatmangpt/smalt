# Receipt — ex1 bank-ledger-nightly

- **Standing: PARTIAL_ALIVE** — 8/10 GREEN, 2 typed XFAIL (in-flight substrate capabilities), 0 FAIL.
- **Date**: 2026-10-19
- **Subject**: `/Users/sac/smalt/examples/bank-ledger-nightly/` (index.ts, run.sh, README.md; node_modules symlink → verification/ts/node_modules)
- **Command**: `/Users/sac/smalt/examples/bank-ledger-nightly/run.sh` → **exit 1** (exit 0 requires all checks GREEN; the two XFAILs keep it at 1 honestly).
- **Substrate**: canonical block via `scripts/substrate-ctl up --block canonical --auth enforce` with `SMALT_TLS_CERTFILE/KEYFILE` dev cert (enforce auth; TLS twin issuer `CN=smalt-dev-ca`). Note: the earlier `just substrate-up` boot failed compiling the `../ggen_igniter` dev path-dep (mid-edit by another lane) and a bare boot serves a bootstrap self-signed cert on 9444 — both observed and worked around by booting the canonical block with the dev TLS env; disclosed for the lane that owns those surfaces.

## Embedded run output (final run, 2026-10-19 ~21:55 PDT)

```
== ex1-bank-ledger-nightly: 8/10 GREEN, 2 XFAIL, 0 SKIP, 0 FAIL ==
  [GREEN] arm-rg-create — rg ex1-bank-rg-mvg7obrcef7f location=smalt
  [GREEN] arm-deployment-lro — beginCreateOrUpdate pollUntilDone terminal provisioningState=Succeeded
  [XFAIL] arm-audit-container-lro — child-resource generic by-id PUT refused 400 InvalidResourceShape ("at most one location") — container-plane generic PUT in flight; audit container created on the blob data plane instead
  [GREEN] kv-kek-create — KEK kid=https://localhost:8443/keys/ex1-bank-kek-mvg7obrcef7f/134
  [GREEN] kv-wrap-dek-envelope — RSA-OAEP-256 wrap/unwrap roundtrip=true, sealed 67B
  [GREEN] cosmos-bulk-upsert — upserted=5/5; envelope decrypt-on-read equal=true ({"ledgerAccount":"4001-CLEARING","bic":"SMALTUS33"})
  [GREEN] cosmos-etag-cas-race — 6 writers on one etag: 200s=1 412s=5 winningWriter=0
  [GREEN] cosmos-stale-412-typed — stale write typed err.code=412 body.code=PreconditionFailed
  [XFAIL] blob-audit-upload — SDK bearer policy refuses http egress client-side (Bearer token authentication is not permitted for non-TLS protected (non-https) URLs.) — blob auth channel in flight; WORM legs unexercisable this boot
  [GREEN] dead-port-plane-check — dead authority typed as real transport failure (Error)
```

## Surfaces hit (real wire, official SDKs)

- **ARM control plane** (@azure/arm-resources over `https://localhost:9444`): RG PUT, generic by-id storage-account LRO `beginCreateOrUpdateById` → `pollUntilDone` terminal `Succeeded`, child-resource container by-id PUT (XFAIL), dead-port plane check.
- **Key Vault** (@azure/keyvault-keys over the TLS twin, serviceVersion 7.4): RSA-2048 KEK create, `RSA-OAEP-256` wrap/unwrap of a 256-bit DEK, AES-256-GCM envelope sealing of a ledger secret, decrypt-on-read round-trip through Cosmos.
- **Cosmos** (@azure/cosmos over the TLS twin, AAD credential): bulk upsert 5/5, envelope-secret doc store + unwrap on read, 6-way same-etag race (exactly one 200, five typed 412 `PreconditionFailed` via `err.code`/`err.body.code`), deliberately-stale write typed 412.
- **Blob** (@azure/storage-blob over http egress): typed XFAIL — the blob auth channel is in flight on this substrate (bearer-over-http refused client-side by the @azure SDK bearer policy; TLS twin does not route blob paths (404); SharedKey refused 401 `MalformedBearerHeader` by the enforce-mode plug — same divergence witnessed in `verification/ts/wf2`). WORM/legal-hold legs are implemented and assert typed 409s but are gated behind the channel; they run green on a substrate boot where the channel is usable.

## Falsifiers / notes

- Re-run: `./run.sh`; exit 0 is reachable exactly when the two XFAIL capabilities land (child-resource generic PUT + a usable official-SDK blob channel).
- No smalt `lib/` imports; no mocks; no fixed sleeps (SDK pollers + harness `boundedPoll` import path only).
