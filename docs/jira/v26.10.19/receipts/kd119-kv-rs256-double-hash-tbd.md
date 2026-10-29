# Receipt — KD-119 vault RS256 sign double-hash

Standing: **UNKNOWN** (witnessed, no fix)
Context: full
Lane: kd-registrar; no lib/ edits.

## Divergence

Vault RS256 `sign` treats the `digest` input as a RAW MESSAGE (hashes it
again before signing) where real AKV expects a pre-hashed digest — a
double-hash. External verification over the digest fails; over the raw
message it verifies — proving the extra hash.

## Witnessed evidence (verbatim from the wf receipt)

`docs/jira/v26.10.19/sdk-results/wf4-py-crypto-custody.md` (2026-10-19):

```
[wf4] KD-14/KD-105 DIVERGENCE SEEN: vault RS256 sign treats the 'digest'
input as a RAW MESSAGE (double-hashes) — real AKV expects a pre-hashed
digest; external cryptography.hazmat verification over the digest FAILED
rc=1 (exit 1); over the raw message it verifies.
```

## Close condition / falsifier

Sign consumes the pre-hashed digest as-is. Falsifier: external
`cryptography.hazmat` verify over the same digest = true, over the raw
message = false (the KD-14/KD-105 inverted polarity).
