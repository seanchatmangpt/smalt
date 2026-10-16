# WS-10 — Attestation Receipt Validator

- Date: 2026-10-15
- Lane: WS-10 (workspace, /Users/sac/smalt/workspace)
- Subject: `workspace/lib/attestation/{validator,canonical,boot-digests}.ts`, `selftest.mjs`, `README.md`
- Blob identity (git hash-object, 12-hex):
  - `validator.ts` b44e4250e9b3
  - `canonical.ts` 5ebbc89720c0
  - `boot-digests.ts` 8f0175f98775
  - `selftest.mjs` e54ef8f39513
  - `README.md` 65455c90c9f4

## Scope

Only lane-disjoint files under `workspace/lib/attestation/`. Scaffold
(tsconfig.json, package.json, lib/serial/protocol.ts) is WS-1/WS-6's —
read, not modified.

## Contract

```
verify(receipt: unknown): Promise<
  | { valid: true; signer: string }
  | { valid: false; reason: string }
  | { refused: 'ALGORITHM_UNSUPPORTED'; algorithm: string }
>
```

Total — never throws on malformed input. Algorithms: `RS256`
(RSASSA-PKCS1-v1_5/SHA-256), `ECDSA-P256` (raw r||s) via WebCrypto
SubtleCrypto, key import from JWK; signatures over the JCS-canonical form
(sorted keys, no whitespace; RFC 8785 subset, pure TS in `canonical.ts`).
Boot-measurement allowlist in `boot-digests.ts` (placeholder entries —
OEM manifest is the production source). SHA-256 helper `sha256Hex`.

Honest boundary: `ML-DSA-65` → typed refusal
`{ refused: 'ALGORITHM_UNSUPPORTED', algorithm: 'ML-DSA-65' }` — no
WebCrypto primitive exists; close condition (documented in-code and in
README): pure-TS FIPS 204 verifier or wasm ML-DSA module behind the same
`verify()` seam. Never a silent pass.

Reason taxonomy: `MALFORMED: ...`, `BAD_SIGNATURE`,
`KEY_OR_ALGORITHM_ERROR: ...`, `BOOT_DIGEST_UNKNOWN_DEVICE`,
`BOOT_DIGEST_DIGEST_MISMATCH`.

The serial-gateway `SIGNED_RECEIPT` shape (WS-6: `sig`, `chipsetSerial`,
`monotonicCounter`) validates as an opaque signed payload; the self-test
signs exactly that shape.

## Verification (real output)

```
$ node lib/attestation/selftest.mjs
PASS RS256 valid=true
PASS ECDSA-P256 valid=true
PASS tampered -> valid=false
PASS cross-algorithm key -> valid=false
PASS ML-DSA-65 -> refused ALGORITHM_UNSUPPORTED
PASS boot digest allowlisted -> valid=true
PASS boot digest mismatch -> valid=false BOOT_DIGEST_DIGEST_MISMATCH
PASS unknown device -> valid=false BOOT_DIGEST_UNKNOWN_DEVICE
PASS total on malformed null
PASS total on malformed undefined
PASS total on malformed 42
PASS total on malformed "receipt"
PASS total on malformed []
PASS total on malformed {}
PASS total on malformed {"algorithm":"RS256"}
PASS total on malformed {"algorithm":"RS256","signerId":"x"}
PASS total on malformed {"algorithm":"RS256","signerId":"x","pay
PASS total on malformed {"algorithm":"ED25519","signerId":"x","p
PASS JCS canonical sorted keys / no whitespace

19 checks passed
$ tsc --noEmit --strict (scoped to lib/attestation/*.ts)
tsc: exit 0, no errors
```

Self-test uses real collaborators (node:crypto webcrypto RSA-2048 and
P-256 keypairs, real subtle.sign/subtle.verify) — no mocks. Chicago
discipline: assertions on final verification state, not interactions.

## Notes / falsifiers

- tsc gate: workspace tsconfig.json (WS-1 scaffold) appeared mid-lane;
  checked with explicit flags scoped to lane files
  (`--ignoreConfig ... --allowImportingTsExtensions`), exit 0.
- Node 26 runs the .ts modules natively (type stripping); imports use
  explicit `.ts` extensions for node ESM resolution.
- Standing: ALIVE for RS256/ECDSA-P256 + canonicalization + totality, as
  witnessed above. `ML-DSA-65` standing is REFUSED (typed), by design.
