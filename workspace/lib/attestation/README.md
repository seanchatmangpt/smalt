# Attestation Receipt Validator (lane WS-10)

WebCrypto verification of signed attestation receipts over their
JCS-canonical (RFC 8785 subset) form. Total — never throws on malformed
input.

## Modules

- `validator.ts` — `verify(receipt)`, `sha256Hex(data)`; algorithm gate,
  shape classification, key import from JWK, `subtle.verify` over the
  canonical bytes.
- `canonical.ts` — `jcsCanonical(value)` / `jcsCanonicalBytes(value)`:
  sorted keys recursively, no whitespace, RFC 8785 number serialization
  (ES6 `Number::toString`). Pure TS, no dependencies.
- `boot-digests.ts` — `KNOWN_BOOT_DIGESTS` (chipsetSerial -> expected boot
  measurement; placeholder entries, replace with the OEM manifest) and
  `checkBootDigest(serial, digest)` returning
  `{ allowed: true } | { allowed: false; reason: 'UNKNOWN_DEVICE' | 'DIGEST_MISMATCH' }`.
- `selftest.mjs` — `node lib/attestation/selftest.mjs`: generates real
  RSA-2048 + P-256 keypairs via `node:crypto` webcrypto, signs canonical
  receipts, and witnesses valid / tampered / ML-DSA-65-refused / boot-digest
  / malformed-totality cases.

## verify() contract

```ts
verify(receipt: unknown): Promise<
  | { valid: true; signer: string }
  | { valid: false; reason: string }
  | { refused: 'ALGORITHM_UNSUPPORTED'; algorithm: string }
>
```

- Never throws; every malformed shape gets a typed `valid: false, reason`
  (`MALFORMED: ...`) or, for recognized-but-unimplemented algorithms, the
  typed refusal `{ refused: 'ALGORITHM_UNSUPPORTED', algorithm }`.
- `reason` taxonomy: `MALFORMED: ...`, `BAD_SIGNATURE`,
  `KEY_OR_ALGORITHM_ERROR: ...`, `BOOT_DIGEST_UNKNOWN_DEVICE`,
  `BOOT_DIGEST_DIGEST_MISMATCH`.
- Algorithms: `RS256` (RSASSA-PKCS1-v1_5 / SHA-256) and `ECDSA-P256`
  (WebCrypto raw r||s) are supported; `ML-DSA-65` is a typed refusal —
  honest boundary, never a silent pass. Close condition: pure-TS FIPS 204
  verifier or wasm ML-DSA module behind the same `verify()` seam.

## Receipt shape

```json
{
  "algorithm": "RS256 | ECDSA-P256",
  "signerId": "device identity (echoed as signer on success)",
  "payload": { ...any JSON value... },
  "signature": "base64url (base64/hex accepted) over JCS(payload)",
  "key": { "...public JWK..." },
  "chipsetSerial": "optional; enables boot-digest allowlist check",
  "bootDigest": "optional; hex boot measurement"
}
```

The serial-gateway `SIGNED_RECEIPT` shape (WS-6: `sig`, `chipsetSerial`,
`monotonicCounter`) validates when carried as the receipt `payload` — the
payload is opaque JSON and the WS-10 self-test signs exactly that shape.

## Verification receipt

```
npx tsc --noEmit (scoped to lib/attestation/*.ts, strict): exit 0
node lib/attestation/selftest.mjs: 19 checks passed
```

See `docs/jira/v26.10.14/receipts/ws-10-attestation.md`.
