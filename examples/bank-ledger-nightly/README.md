# ex1 — Bank core-ledger nightly batch

A Fortune-500 archetype: every night at close, the core-ledger runs its
batch — it provisions its batch infrastructure through ARM (resource group +
storage account via a deployment-style LRO), seals the day's ledger secrets
under a Key Vault key, upserts the day's postings into the ledger database
with optimistic concurrency (etag CAS), and exports an immutable audit
record to blob storage under WORM.

Every step asserts real wire state with the official `@azure/*` SDKs —
zero mocks, zero fixed sleeps (bounded polls / SDK LRO pollers only), typed
SDK exceptions, real TLS to the substrate's TLS twin.

## The nightly story, step by step

1. **ARM provisioning** — the batch creates its resource group, then a
   storage account through `resources.beginCreateOrUpdateById` →
   `pollUntilDone()` to a terminal `provisioningState=Succeeded`. The audit
   container is attempted through ARM too; on the current substrate the
   child-resource generic by-id PUT is refused by the graphlaw validator
   (typed XFAIL), so the container is created on the blob data plane instead.
2. **Envelope encryption** — the batch mints an RSA-2048 KEK in Key Vault,
   wraps a random AES-256 DEK with `RSA-OAEP-256`, AES-GCM-encrypts the
   ledger's account-mapping secret, and stores the ciphertext + wrapped DEK
   as a ledger document. On read the DEK is unwrapped through the KEK and
   the secret is decrypted — key-encryption-of-secrets, proven by a full
   wire round-trip (encrypt → store → read → unwrap → decrypt → compare).
3. **Ledger upsert with CAS** — five ledger rows are bulk-upserted into
   Cosmos. Then six concurrent writers race to replace one row conditioned
   on the SAME etag: exactly one wins with 200, the other five get the typed
   412 `PreconditionFailed` (the @azure/cosmos error carries the status on
   `err.code` and the typed code on `err.body.code`). A deliberately stale
   write is then asserted to fail with the same typed error.
4. **Audit export + WORM** — the batch exports a JSON audit record to blob
   storage and (when the blob channel is exercisable) sets a legal hold,
   asserts that overwrite/snapshot/delete all refuse with typed 409s, checks
   the immutability policy plane, and clears the hold. On the current
   substrate boot the blob auth channel is in flight (see verdicts), so this
   leg is a loud typed XFAIL — never a fake pass.

## Prerequisites

- smalt substrate UP on the loopback ports (ARM 9443, TLS twin 9444, egress
  8443): `just substrate-status` / `just substrate-up` — and serving the
  dev TLS cert on 9444 (`issuer=CN=smalt-dev-ca`; a boot without
  `SMALT_TLS_CERTFILE`/`SMALT_TLS_KEYFILE` serves a bootstrap self-signed
  cert that the harness will refuse).
  Bootable with dev TLS via:
  `SMALT_TLS_CERTFILE=$PWD/.smalt/tls/dev-cert.pem SMALT_TLS_KEYFILE=$PWD/.smalt/tls/dev-key.pem scripts/substrate-ctl up --block canonical --auth enforce`
- TLS dev material: `bash scripts/gen_dev_cert.sh` (`.smalt/tls/ca-cert.pem`)
- Node >= 22 (type stripping) — no build step, no extra install: the pinned
  official `@azure/*` SDKs resolve from `verification/ts/node_modules`
  (this example's `node_modules` is a relative symlink to it).

## Run

```bash
cd examples/bank-ledger-nightly
./run.sh            # exit 0 pass / 1 fail / 2 substrate down / 3 skip
```

or manually:

```bash
eval "$(just relay-env)"            # SMALT_* endpoints, AZURE_* creds
export NODE_EXTRA_CA_CERTS="$PWD/.smalt/tls/ca-cert.pem"
node index.ts
```

Endpoints are env-overridable: `SMALT_ARM` (token STS, default
`http://127.0.0.1:9443`), `SMALT_ARM_TLS` (SDK baseUri, default
`https://localhost:9444`), `SMALT_TLS` (kv + cosmos twin, default
`https://localhost:9444`), `SMALT_EGRESS` (blob data plane, default
`http://127.0.0.1:8443`).

## Exit contract

| exit | meaning |
|---|---|
| 0 | all checks GREEN |
| 1 | a real FAIL, or XFAIL verdicts present (in-flight capabilities, loudly marked) |
| 2 | substrate never came up |
| 3 | nothing runnable (all legs skipped) |

`XFAIL` is an expected failure against an in-flight substrate capability,
recorded with the wire evidence; it is NOT a pass and keeps exit at 1 until
the capability lands. Current XFAILs (both witnessed by the wf2/census
receipts and reproduced here): child-resource generic by-id PUT (graphlaw
"at most one location") and the blob auth channel under enforce auth
(bearer-over-http is refused client-side by the SDK's bearer policy; the
TLS twin does not route blob paths; SharedKey is refused 401
MalformedBearerHeader by the enforce-mode plug).
