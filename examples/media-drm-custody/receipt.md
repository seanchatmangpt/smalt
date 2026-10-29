# Receipt — ex6 media-drm-custody

Date: 2026-10-19
Lane: ex6 (Fortune-500 archetype "Media DRM key custody")
Repo: /Users/sac/smalt (absolute; lane owns only
`examples/media-drm-custody/**`)

Standing: **PARTIAL_ALIVE** — 5/8 checks GREEN on the real wire, 1
REGISTERED-DIVERGENCE#KD-119 (externally confirmed), 1 typed XFAIL
(deleted-keys plane not landed, skip-until-landed marker matching lane
ex3's witness), 1 typed SKIP-SURFACE-ABSENT (SKR). Exit code 0
(pass-with-registered-divergence per the exit-code contract). No real
FAILs.

## What ran

- Substrate: canonical block UP on 9443/9444/8443/5672/5673 (auth enforce,
  dev TLS CA, `NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem`). One mid-lane
  substrate drop (another lane's boot cycle) was ridden out by polling
  `just substrate-status` and rerunning on the returned beam — no lane
  substrate was evicted or booted.
- Official `@azure/keyvault-keys` KeyClient + CryptographyClient from the
  verification tier's pinned node_modules (symlinked), `serviceVersion
  "7.4"`, `disableChallengeResourceVerification` per the wf4 pattern.
- Zero mocks, no fixed sleeps, typed SDK exceptions, real TLS wire.

## Checks (final run)

```
$ bash run.sh
== ex6-media-drm-custody: 5/8 GREEN, 1 REGISTERED-DIVERGENCE, 1 XFAIL, 0 SKIP, 0 FAIL ==
  [GREEN] kv-create-rsa2048-kek — kid=https://localhost:8443/keys/ex6-drm-kek-mvg83j9p4930/1028
  [GREEN] kv-wrap-rsa-oaep — wrapKey RSA-OAEP-256 -> 256-byte wrapped content key
  [GREEN] kv-unwrap-roundtrip — unwrapKey roundtrip equal=true (content key 256-bit)
  [GREEN] kv-fetch-public-jwk — public JWK fetched kty=RSA n=247b64url-chars
  [REGISTERED-DIVERGENCE#KD-119] kv-rs256-external-verify — external verify=true ONLY over the raw message (license doc), never the digest — substrate sign treats the digest input as a raw message (KD-119 double-hash), confirmed externally in a child process
  [GREEN] kv-soft-delete — DELETE /keys/ex6-drm-kek-mvg83j9p4930 -> 200
  [XFAIL] kv-deletedkeys-plane — GET /deletedkeys/ex6-drm-kek-mvg83j9p4930 -> 404 — deleted-keys plane not landed; recover/purge unexercisable (skip-until-landed)
  [SKIP-SURFACE-ABSENT] kv-skr-release — POST /keys/ex6-drm-kek-mvg83j9p4930/release -> 404 — SKR release surface absent on substrate (typed skip)
EXIT=0
```

Two consecutive green runs at exit 0 (confirmation rerun identical modulo
fresh key names).

## KD-119 external confirmation (new evidence, no register edit)

The lane's external child-process verifier independently reproduced the
KD-119 double-hash polarity from TypeScript: recovering the PKCS#1 v1.5
encoded message with `RSA_NO_PADDING` shows a well-formed
`DigestInfo(SHA-256)` whose hash equals `sha256(raw_message)` — the
substrate treats the `sign` digest input as a raw message. Node
`crypto.verify` is true only over the raw message, never the submitted
digest. This is the same polarity the wf4-py hazmat witness recorded;
existing KD-119 row applies, no new KD minted by this lane.

## In-flight capability markers (typed, loud)

- `kv-deletedkeys-plane` XFAIL: `/deletedkeys` read plane absent on the
  running substrate build (same marker as lane ex3's KD-102
  skip-until-deleted-keys-landed witness). Full recover/purge assertions
  are already in the harness and activate when the plane lands.
- `kv-skr-release` SKIP-SURFACE-ABSENT: `POST /keys/{name}/release` -> 404.

## Files

- `examples/media-drm-custody/index.ts` — harness (KV wrap/unwrap envelope,
  RS256 sign + external child-process verify, soft-delete lifecycle, SKR)
- `examples/media-drm-custody/run.sh` — one-command runner (exit 0/1/2/3)
- `examples/media-drm-custody/README.md` — business story + leg table
- `node_modules` symlink -> `verification/ts/node_modules` (no installs)

---

## Integration note (coordinator, 2026-10-19 post-landing flip attempt)

Capability commit `8ca1b82` (KV deleted-keys/secrets planes, RBAC+locks)
landed mid-wave; the harness's pre-coded flip assertions were re-run twice
on freshly compiled canonical beams. Verdict: the plane is still not served
(`/deletedkeys`/`deletedsecrets` 404; RG-scope locks 501
LockSurfaceNotImplemented at arm_gateway/router.ex:982) — XFAIL stands,
never faked. Full recover/purge/lock assertions are coded and activate on
the first serving beam. Confounder: an outside actor cycled the shared
substrate during the window (5 beam pids observed); verdicts are
as-of-beam.
