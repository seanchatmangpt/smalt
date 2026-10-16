# Receipt — Bench Lane C-4: Key Vault envelope-encryption -> Cosmos

- **Lane**: c4 (cross-product bench wave, v26.10.14)
- **Repo**: `/Users/sac/smalt` (canonical checkout)
- **Script (owned)**: `scripts/bench/c4_kv_cosmos_crypto.mjs`
- **Result file (owned)**: `docs/jira/v26.10.14/bench/c4-kv-cosmos.jsonl` (9 rows: 8 measured + 1 meta summary)
- **Run**: 2026-10-16T03:53:39Z, sequential, warmup-excluded (20/phase), rc=0, 0 errors
- **Standing**: ALIVE — all phases executed against a live lane-private substrate

## Subject

Real `@azure/keyvault-keys` CryptographyClient (RSA-OAEP-256, challenge-based
auth with `disableChallengeResourceVerification` — the substrate's enriched 401
challenge is honored, same handshake the KV probe witnesses) + real
`@azure/cosmos` against a lane-private substrate (MIX_ENV=test, ports
39040..39045, vault on TLS 39044). Envelope pattern: per-doc DEK wrapped by a
KV KEK, 3 fields per doc encrypted locally with AES-256-GCM under the DEK,
wrapped DEK + base64 field ciphertexts stored as Cosmos docs. Auth-tag
verification on every field decrypt — a bad tag throws and would have counted
as an error; zero occurred.

## Crypto-tax table (the deliverable)

| phase | op | n | ops/s | p50 | p95 | p99 ms | err |
|---|---|---|---|---|---|---|---|
| 1 floor | KV encrypt RSA-OAEP-256 (32 B) | 100 | 1367.4 | 0.697 | 0.945 | 1.012 | 0 |
| 1 floor | KV decrypt RSA-OAEP-256 | 100 | 399.9 | 2.450 | 2.983 | 4.036 | 0 |
| control | cosmos create plaintext | 200 | 1984.0 | 0.479 | 0.721 | 0.791 | 0 |
| control | cosmos point-read plaintext | 200 | 2618.9 | 0.342 | 0.575 | 0.982 | 0 |
| 2 | envelope write: KV wrap per doc + local AES x3 + create | 200 | 843.1 | 1.154 | 1.566 | 1.679 | 0 |
| 3 | envelope read: read + KV unwrap per doc + local AES x3 | 200 | 456.9 | 2.105 | 2.770 | 3.550 | 0 |
| 4 | key-reuse write: 1 KV op total, cached DEK | 200 | 1774.0 | 0.460 | 0.766 | 1.154 | 0 |
| 4 | key-reuse read: 0 KV ops, hot DEK | 200 | 2310.8 | 0.389 | 0.700 | 0.940 | 0 |

## Crypto-tax multipliers

| surface | plaintext | envelope | tax | cached-DEK | tax | cached-DEK speedup |
|---|---|---|---|---|---|---|
| write | 1984.0/s | 843.1/s | **2.35x** | 1774.0/s | **1.12x** | 2.10x |
| read | 2618.9/s | 456.9/s | **5.73x** | 2310.8/s | **1.13x** | 5.06x |

## Key findings

1. Naive per-field envelope (KV op per doc) taxes reads 5.73x, writes 2.35x.
2. The Azure-documented cached-DEK pattern collapses the tax to ~1.1x on both
   surfaces — the KV round-trip is the tax, not the AES: local AES-256-GCM
   over 3 fields plus one Cosmos round-trip is nearly free relative to
   plaintext.
3. KV decrypt (p50 2.45 ms) is ~3.5x KV encrypt (p50 0.70 ms) — the RSA
   private-key op dominates, so reads pay the bigger tax. Any per-read unwrap
   is the first thing to cache.
4. Baseline context: B-3's shared-substrate plaintext read is 4405/s; our
   lane-local control measured 2618.9/s in the same boot — against the shared
   substrate the observed envelope tax would be higher still.

## Machine

`{"cpu":"Apple M4 Pro","cores":14,"ram_gb":24,"elixir":"1.19.5","otp":"28","darwin":"15.6.1"}`

## Deviations (disclosed)

1. **TLS trust**: bench_boot's eval sets no TLS cert config, so the vault
   serves its port-keyed auto dev cert (`tmp/dev-certs/dev-cert-39044.pem`,
   self-signed leaf). Pointing the substrate at the CA-signed
   `.smalt/tls/dev-cert.pem` failed at boot with
   `{:corrupt_certfile, ..., :unparseable_key}` — pre-existing substrate
   cert-parse limitation on PKCS#8 dev-key.pem (not repaired; lib edits out of
   lane scope). Final run: bench_boot as-is + client-side
   `NODE_EXTRA_CA_CERTS=tmp/dev-certs/dev-cert-39044.pem` (leaf-as-anchor; TLS
   verification active, not disabled).
2. **kid rewrite**: the substrate returns kids advertising the canonical front
   door (`https://127.0.0.1:8443/...`); the script rewrites the kid host to the
   lane vault base (`https://127.0.0.1:39044`) so crypto ops hit the
   lane-local substrate. SDK createKey (PUT /keys/:name) returned 400
   InvalidBody, so the KEK is created via the substrate-native
   `POST /keys/:name/create` route (both routes witnessed in
   `test/sdk-full/keyvault.probe.mjs`).
3. **First run discarded**: an earlier run had 20 x 409 errors on the plaintext
   create baseline (warmup and measured loops shared doc ids); fixed
   (`fn(i, warm)` prefix split), rerun clean. The discarded run's jsonl was
   deleted before the clean run; the receipt cites only the clean run.

## Falsifier status

- Phase-4 delta is real: same DEK, only KV-op count changes (200 -> 1 -> 0),
  and throughput moves 843 -> 1774 (write), 457 -> 2311 (read). If the KV op
  were not the bottleneck, those deltas would not appear.
- AES decrypts are authenticated (`final()` throws on tag mismatch) — the read
  phases return zero errors, so decrypted fields verified on every doc.

## Teardown

Substrate down after run: ports 39040/39044 confirmed free post-run. No
commits, no lib edits. Files touched: the three lane-owned files only.
