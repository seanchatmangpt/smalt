# Media DRM Key Custody (ex6)

Fortune-500 archetype: a streaming platform's DRM service never sees a raw
content key. The studio mints an RSA key-encryption key (KEK) in Key Vault,
wraps each title's content key with RSA-OAEP-256, and licenses players by
signing license digests with RS256 — where the license server **verifies the
signature with the public JWK fetched over the wire from the vault**, never
with a shared secret. Suspected-compromised keys go through the soft-delete
recovery window (recover on false alarm, purge when confirmed). Secure Key
Release (SKR) is the confidential-computing path for releasing keys only to
attested enclaves.

## What the harness does

| Leg | Check | Verdict this boot |
|---|---|---|
| 1 | RSA-2048 KEK create (`KeyClient.createKey`) | GREEN |
| 1 | Content-key wrap/unwrap roundtrip (`CryptographyClient`, RSA-OAEP-256) | GREEN |
| 2 | Public JWK fetch (`getKey`) | GREEN |
| 2 | RS256 license-sign + **external** `node:crypto` verify in a child process against the fetched JWK | REGISTERED-DIVERGENCE#KD-119 |
| 3 | Soft-delete (`DELETE /keys`) | GREEN |
| 3 | Deleted-keys plane (get/recover/purge) | XFAIL — plane not landed on substrate |
| 4 | SKR `POST /keys/{name}/release` | SKIP-SURFACE-ABSENT (404) |

## The external-verification leg (why it is shaped this way)

The signature is verified in a **separate child process** that receives only
`node:crypto`, the raw license message, the submitted digest, the signature,
and the public JWK parts — no substrate handle, no SDK objects, no shared
in-process state. If the child prints a verdict, the signature really
verifies under that public key; the check cannot be tautological.

The probe verifies two polarity shapes:

- **spec** — RS256 over the submitted digest (Azure contract: `sign` takes a
  pre-hashed digest).
- **message** — RS256 over the raw message (substrate treats the digest
  input as a raw message and hashes it once).

Witnessed 2026-10-19 on the running substrate: the recovered PKCS#1 v1.5
encoded message carries a well-formed `DigestInfo(SHA-256)` whose hash is
`sha256(raw_message)`, never the digest the client submitted — so the
signature verifies **only** in the message shape. This is the KD-119
double-hash divergence (vault RS256 sign), independently confirmed from
TypeScript after the Python (hazmat) witness; the verdict is
`REGISTERED-DIVERGENCE#KD-119`, citing the existing register row
(`docs/jira/v26.10.19/KNOWN_DIVERGENCES.md`) — no new KD minted.

## Soft-delete lifecycle

`DELETE /keys/{name}` is GREEN (soft delete works), but the `/deletedkeys`
read plane (get / recover / purge) is not landed on the currently running
substrate build — `GET /deletedkeys/{name}` answers 404. Per the lane
contract this is a **typed XFAIL** (`kv-deletedkeys-plane`, "skip-until-
deleted-keys-landed"), matching the marker witnessed by lane ex3 — never a
fake pass. When the plane lands, the harness already contains the full
recover → get-alive → purge → 404-after-purge assertions and they activate
automatically.

## SKR

`POST /keys/{name}/release` answers 404 on this substrate: the SKR surface
is absent, reported as a loud `SKIP-SURFACE-ABSENT` with the wire status in
the detail.

## Run

```bash
cd examples/media-drm-custody && bash run.sh
```

Endpoints are env-overridable (`SMALT_ARM`, `SMALT_TLS`, `SMALT_EGRESS`);
defaults target the canonical loopback substrate. SDKs resolve from the
verification tier's pinned `@azure/*` node_modules (symlinked). Exit
contract: 0 pass (incl. pass-with-registered-divergence) / 1 fail /
2 substrate down / 3 loud skip.

## Conventions

Official `@azure/keyvault-keys` SDKs over the real TLS wire, zero mocks, no
fixed sleeps, typed SDK exceptions asserted on real state. Conventions
copied from the `verification/` tier (wf4 sign/verify pattern, ex1 envelope
pattern).
