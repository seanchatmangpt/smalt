# SCVD-T23 — Serial latency floor profile (cosmos point-read / blob GET / KV GET)

**Standing:** **ALIVE** (measured-only profile; no fence, no pass/fail).

- Date: 2026-10-21
- Subject: live substrate (pid 8877), 9444 TLS twin, working SDK path
- Harness: `tmp/bench/scvd_floor.mjs` (auth mirrors `tmp/bench/scvd_tier1.mjs`: STS
  bearer minted from ARM 9443 `POST /organizations/oauth2/v2.0/token`, 1290-char
  bearer, tokenProvider into all three SDK clients)
- Shape: single connection, strictly serial, n=1000 per face, 256 B payloads
- Result file: `tmp/bench/scvd-floor.jsonl`
- Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}` (`just bench-machine`)

## Table (measured-only)

| face              | n    | ok   | errors | min_ms | p50_ms | p99_ms | max_ms | ops/s (ceiling) |
|-------------------|------|------|--------|--------|--------|--------|--------|-----------------|
| cosmos-point-read | 1000 | 1000 | 0      | 0.477  | 0.687  | 3.040  | 69.674 | 1072.8          |
| blob-get          | 1000 | 1000 | 0      | 1.149  | 1.369  | 2.731  | 9.648  | 686.4           |
| kv-get            | 1000 | 1000 | 0      | 0.383  | 0.519  | 1.322  | 3.219  | 1778.4          |

## Notes

- Verdict = measured-only, as specified; no fence applied.
- Cosmos wall includes one 69.7 ms outlier (single-connection head-of-line
  stall); min/p50 show the true per-request floor (~0.48–0.69 ms).
- Blob GET is the floor-dominant face: ~2.4x cosmos p50, driven by the
  storage SDK's heavier request pipeline per serial round trip.
- KV GET (KeyVault `getKey` via `@azure/keyvault-keys`) is the fastest face;
  the serial ceiling across faces spans 686–1778 ops/s, consistent with the
  per-request substrate floor APEX-2 cited.
- KeyClient required `disableChallengeResourceVerification: true` (loopback
  vault-URI challenge check against 127.0.0.1).

## Commands

```
NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem node tmp/bench/scvd_floor.mjs
# -> 3 faces, 3000/3000 ops ok, 0 errors, WROTE tmp/bench/scvd-floor.jsonl
```
