# kd105-ps256-external-verify-tbd.md — evidence receipt (kd-lane, 2026-10-19)

- **KD row**: KD-105 (PS256 not externally verifiable)
- **Standing**: OPEN — divergence RE-WITNESSED this window on two external-SDK legs; no closing receipt exists
- **Context**: solo

## Evidence (all on-disk, this window)

### 1. TS external suite — sign-external-verify cell SKIPs citing KD-105/KD-14

`docs/jira/v26.10.19/sdk-results/wf4-ts-crypto-custody.md`:

```
16:keyvault:sign-external-verify: keyvault/sign-external-verify SKIP (KD-105, KD-14)
```

Runner tail (same file):

```
[REGISTERED-DIVERGENCE#KD-14,KD-105] kv-sign-external-verify — external node:crypto verify=false (child status=0) — signature-shape divergence per KD-14/KD-105
```

(The runner labels the cell `REGISTERED-DIVERGENCE` — the harness admits the divergence
is real and registered rather than passing it silently.)

### 2. PY external suite — external verifier refuses the substrate signature (rc=1)

`docs/jira/v26.10.19/sdk-results/wf4-py-crypto-custody.md` (captured stdout, `test_challenge_then_crypto_lifecycle`):

```
[wf4] KD-14/KD-105 DIVERGENCE RECORDED: vault RS256 sign treats the 'digest' input as a RAW MESSAGE (double-hashes) — real AKV expects a pre-hashed digest; external cryptography.hazmat verification over the digest FAILED rc=1; over the raw message it verifies.
```

Witness law of the row: external `cryptography.hazmat` verification over the digest
**FAILED rc=1**; over the raw message it verifies — the same signature-shape class as
the KD-14 RS256 inversion, distinct algorithm.

### 3. Source pin

`lib/smalt/data_plane/key_vault_actions.ex` sign path — digest-vs-raw-message treatment is the
mechanism the two witnesses above exercise. No `# KD-COVERS: KD-105` shim exists in
`lib/` (kd_flip scan: KD-105 absent from the 30-id covers-map).

## Standing rationale

The row registers the divergence; both external-suite legs re-witnessed it this window
(SKIP-as-registered-divergence on the TS leg, external-verifier rc=1 on the PY leg).
Skeleton falsifier ("external Node WebCrypto verify = true against the public JWK") was
NOT achieved — no close receipt. **KD-105 stays OPEN**; close requires the PS256
signature to verify true externally with a tampered control false.

## Cross-links

- KD-14 (RS256 inversion) — same signature-shape class; wf4-py leg witnesses both.
- kd109/kd110/kd111/kd112 evidence receipts in this directory.
