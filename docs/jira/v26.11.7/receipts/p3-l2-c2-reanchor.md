# P3-L2 — C2 re-anchor receipt (arcus Go membrane)

Standing: PARTIAL_ALIVE

Lane P3-L2, 2026-11-05. Repos: smalt (read + C2 doc append), arcus (anchor
comments only — three hand-written dialect files, never generated).

## What landed

1. `/Users/sac/arcus/internal/dialect/azure/kv7.go` — 6 anchor comments
   appended (rows 2/2c/2d, 4/5, 1/17, soft-delete KD-102, GAP 7/8, row 6).
2. `/Users/sac/arcus/internal/dialect/azure/armkv.go` — 4 anchor comments
   appended (rows 6/19, KD-15 challenge posture, error envelope rows 1/17,
   GAP 7/8).
3. `/Users/sac/arcus/internal/dialect/azure/attestation.go` — 6 anchor
   comments appended (row 13 MAA flat claims, row 11 SKR admission,
   row 12 jti/nonce replay, row 10 KeyNotExportable, GAP rows 7/8,
   attest-path locus).
4. `/Users/sac/smalt/docs/compliance/C2_KEYVAULT.md` is UNTOUCHED in its
   original rows; a single "Arcus anchors (lane P3-L2, 2026-11-05)"
   section appended with the 12-row anchor table and verdicts. (Typo in
   this receipt: the real path is `C2_KEYVAULT.md`.)

## Anchor/locus census (re-read from disk at receipt time)

```
$ grep -c '<- arcus:' arcus/internal/dialect/azure/{kv7,armkv,attestation}.go
kv7: 6
armkv: 4
attestation: 6
total: 16
```

16 markers = 16 anchored loci (12 table rows; rows 7/8 appear in all
three Go files as UNSUPPORTED(gap-both-sides) markers that name no
Go-side anchor — they are the no-flip witnesses, counted in the 16).
Gate: marker count matches anchored loci; no GAP row flipped (rows
2a/7/8 remain GAP in `C2_KEYVAULT.md`, untouched original rows).

## Per-anchor verdicts

| # | C2 locus | smalt:lines (real from disk) | arcus:lines | verdict |
|---|---|---|---|---|
| 1 | encrypt/decrypt/wrap/unwrap + sign/verify face | key_vault_actions.ex:56-76 (defdelegate facade; crypto engine in KeyVault.Keys) | kv7.go:54-90 | ANCHORED — row 2a AAD GAP residue unchanged |
| 2 | list delegates (rows 4/5) | key_vault_actions.ex:78-82 | kv7.go:43-49, 61-71 | ANCHORED — row 4 is a smalt-only extension, no arcus counterpart |
| 3 | error face rows 1/17 | skr.ex:404-431 error bodies; facade has no error body | kv7.go:226-296 Kv7ErrCode + armkv.go:88-104 | ANCHORED — innererror unmodeled both sides |
| 4 | soft-delete lifecycle KD-102 | key_vault_actions.ex:96-109 | kv7.go:212-296 | ANCHORED |
| 5 | create/list projection rows 6/19 | key_vault_actions.ex:84-85, 78-82 | armkv.go:24-104 | ANCHORED — row 6 PARTIAL residue unchanged |
| 6 | KD-15 api_version/challenge_mode | key_vault_actions.ex:36-50 | armkv.go:135-162 ("7.4" pin) | ANCHORED |
| 7 | GAP rows 7/8 (release contract) | skr.ex:255-285 | none (kv7/armkv/attestation all carry no target/enc/nonce, no signed object) | UNSUPPORTED(gap-both-sides) — GAP stays GAP, no flip |
| 8 | skr.ex authorized?/1 row 11 | skr.ex:131-157 + 171-190 | attestation.go:713-743 + 770-781 | ANCHORED — arcus verifyAttestedClaims (:744-758) decodes WITHOUT RS256 signature verification; registered divergence, disclosed not flipped |
| 9 | skr.ex jti single-use row 12 | skr.ex:201-223 | attestation.go:584-679 nonce table | ANCHORED — arcus code spelling nonceReplay vs smalt TokenReplay (row 17) |
| 10 | skr.ex fetch_exportable row 10 | skr.ex:109-123 | attestation.go:74-75 typed codes | ANCHORED |
| 11 | attest_enclave row 13 | attestation.ex:28-76 (flat claims 57-68) | attestation.go:472-562 Attest + buildClaimsEnvelope | ANCHORED — flat x-ms-isolation-tee minted BOTH sides, row 13 PARTIAL unchanged; arcus runtime-claims superset disclosed |

## Verification ladder

- `gofmt -l internal/dialect/azure/` — my three files clean (pre-existing
  `kv7_wire_court_test.go` unformatted — NOT this lane's file, disclosed).
- `go vet ./internal/dialect/azure/` — exit 0.
- Anchor marker gate: 16 `<- arcus:` = 16 anchored loci.
- C2 doc original rows untouched — zero GAP flips (2a/7/8 remain GAP).

## Honest residues

- `key_vault_actions.ex` is now a 184-line defdelegate facade; the C2
  doc's old citations (e.g. `key_vault_actions.ex:835-841`) are stale —
  anchors cite the facade regions plus the impl faces (skr.ex /
  attestation.ex) that still carry bodies. Facade-region anchors are the
  current disk truth.
- arcus `verifyAttestedClaims` (attestation.go:744-758) decodes the JWT
  payload without RS256 verification (engine-bound boundary, documented
  in-file); smalt fully verifies. Disclosed, not flipped.
- arcus `complianceStatus` (attestation.go:770-781) already accepts the
  nested MAA form — the Go side AHEAD of the smalt mint side (row 13
  PARTIAL stays PARTIAL).
- No git actions taken (lane contract).
