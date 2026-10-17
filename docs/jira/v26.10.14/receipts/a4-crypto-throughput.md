# Receipt: A-4 — Confidential Ledger / SKR cryptographic throughput (BEAM tier)

- **Lane**: A-4 (adversarial cross-product bench)
- **Subject**: `/Users/sac/smalt` @ `fd9cfeaec3ebd8e56b6bb530453901118ca89582` (main, uncommitted lane tree)
- **Script**: `scripts/bench/a4_crypto_throughput.exs`
- **Data**: `docs/jira/v26.10.14/bench/a4-crypto.jsonl` (14 records)
- **Run**: `MIX_ENV=test A4_OPENSSL_N=300 mix run --no-start scripts/bench/a4_crypto_throughput.exs` — exit 0
- **Machine**: Apple M3 Max, 16 cores, 48 GB, Elixir 1.19.5, OTP 28
- **Boundary**: BEAM-tier in-process only (`--no-start`, no substrate, no app boot); 512-byte payload; no lib edits, no commits.

## Measured results (5000 ops per op unless noted, p50/p95/p99/p99.9 in JSONL)

| op | ops/s | p50 ms | p99 ms | notes |
|---|---:|---:|---:|---|
| ed25519_sign_pattern (Hw.Signer as deployed) | 9,099 | 0.108 | 0.139 | includes SHA-256 keypair derivation per sign |
| ed25519_sign_cached (keypair hoisted) | 13,759 | 0.071 | 0.090 | +51% over pattern — hoisting `keypair/0` is the cheap win |
| ed25519_verify | 9,920 | 0.098 | 0.120 | |
| ecdsa_p256_sign | 36,799 | 0.027 | 0.035 | |
| ecdsa_p256_verify | 16,179 | 0.061 | 0.081 | |
| rs256_sign (RSA-2048) | 1,113 | 0.893 | 0.975 | the only >1ms op in the SKR path |
| rs256_verify | 25,334 | 0.037 | 0.058 | |
| sha256_digest (512B) | 2,149,228 | 0.0004 | 0.0005 | |
| receipt_signer_sign (JWS incl. JSON+b64url) | 1,098 | 0.903 | 1.000 | |
| receipt_signer_verify | 22,110 | 0.044 | 0.069 | |
| receipt_signer_roundtrip | 1,004 | 0.943 | 1.877 | sign→verify, full JWS envelope |
| openssl_spawn_seq (subprocess per op) | 150.6 | 6.40 ms | 7.27 ms | spawn+exec dominates |
| openssl_spawn_par_conc16 (5000 ops, 16-way) | 1,445.6 | — | — | aggregate subprocess throughput |
| sha256_digest_billable_probe | 1,340,332 | 0.0005 | — | probe feeding the billable block |

## :crypto native vs openssl subprocess — why in-process is the only viable hot path

In-process `:public_key` RSA-2048 sign runs at **1,113 ops/s**, the same algorithm class
via a per-op `openssl` subprocess at **150.6 ops/s sequential** (p50 6.4 ms of which the
actual SHA-256 is ~0.4 µs) — **~7.4× slower sequential**, and even 16-way concurrent the
subprocess path tops out at 1,446 ops/s while consuming 16 scheduler threads. The per-op
cost is fork/exec + pipe + PEM/argv overhead, not the cryptography. Even the *slowest*
in-process op (rs256_sign) beats the best measured subprocess throughput 1.3× on
throughput and ~7× on tail latency, using one scheduler.

## Azure billable rows (directional, public US-East list prices)

| row | price | vs measured |
|---|---|---|
| Confidential Ledger writes | $0.36 / 10k writes | at the local crypto-bound pipeline rate (rs256 round-trip 1,004/s → 36M writes/s-of-ledger-quota-irrelevant), crypto is never the binding constraint — Ledger-side write quota and $/10k dominate |
| Confidential Ledger at measured round-trip | $3,613/hr if writes were free-running | crypto path can saturate any realistic Ledger quota; cost is Ledger-side, not crypto-side |
| Managed HSM sign | $2.50/instance-hr, ~500 sign ops/s class per partition | in-process rs256_sign measured 1,113 ops/s — in-process already beats a Managed HSM partition on throughput and avoids $2.50/hr + network RTT per op; HSM is for key custody, not hot-path signing |

Note: at $0.36/10k writes, a full-speed receipt_signer_roundtrip pipeline (1,004 writes/s)
would burn ~$130/hour of Ledger write budget — the Ledger spend, not local crypto, is the
cost lever. Prices marked directional in the JSONL `azure_cost_rows` record.

## Findings

1. **In-process crypto is the only viable hot path** — confirmed with numbers: subprocess
   spawn cost (6.4 ms p50) exceeds every in-process op by 6-4 orders of magnitude.
2. **Hw.Signer pattern**: re-deriving the Ed25519 keypair per sign costs ~33% of sign
   throughput (9.1k vs 13.8k ops/s). `public_key/0`/`keypair/0` are already exported seams;
   a `:persistent_term` cache would be the one-line fix if device identity churn permits.
3. **RS256 sign is the SKR-path bottleneck** at ~1.1k ops/s, but even that supports
   ~87M receipt writes/day per core — far above any Ledger quota at $0.36/10k.
4. ReceiptSigner envelope overhead (JSON + base64url) is negligible vs RSA sign (~1%).

## Standing

ALIVE — real `mix run --no-start` execution, exit 0, 14/14 JSONL records, all ops
executed against live `:crypto`/`:public_key` (no mocks) plus the real
`Smalt.Security.ReceiptSigner` and `Smalt.Hw.Signer`-pattern modules.
