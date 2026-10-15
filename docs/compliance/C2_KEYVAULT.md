# C2 — Key Vault / Managed HSM Data-Plane Surface vs Real Azure Contract

Compliance court for smalt's Key Vault / Managed HSM data-plane surface against
the real Key Vault REST 7.x contract and the Secure Key Release (SKR) spec.
Every row carries a code citation and live-probe evidence; CONFORMANT rows are
fenced by `test/compliance/c2_keyvault.exs` (16 tests, 0 failures,
2026-10-15; lens-3 added C2.4b response-content-type cross-court fence). Sibling suites `test/kv_tls_test.exs` +
`test/data_plane/key_vault_actions_test.exs`: 38 tests, 0 failures.

Sources: [encrypt](https://learn.microsoft.com/en-us/rest/api/keyvault/keys/encrypt/encrypt),
[verify](https://learn.microsoft.com/en-us/rest/api/keyvault/keys/verify/verify),
[release](https://learn.microsoft.com/en-us/rest/api/keyvault/keys/release/release)
(Rest 2025-07-01 pages, fetched 2026-10-14); MAA claim structure per
[SKR flow for CVMs](https://learn.microsoft.com/en-us/azure/confidential-computing/skr-flow-confidential-vm-sev-snp).

## Verdict summary

**PARTIAL** overall: the crypto core (algs, RSA-OAEP-256 / A256GCM / RS256 /
PS256, base64url wire encoding, digest-based sign/verify contract, error
envelope, TLS, SKR admission + replay, release-policy schema) is CONFORMANT;
the remaining GAP cluster is the release contract: real `target`/`enc`/`nonce`
request body and a signed-object release response. Dev-material derivations
(derived oct keys, HKDF release material) are documented design deviations,
not gaps.

## Rows

| # | Surface | Verdict | Evidence |
|---|---|---|---|
| 1 | Error envelope `{"error":{"code","message"}}` | CONFORMANT | `key_vault_actions.ex:399-405`, `skr.ex:268-304`. Probe C2.4/C2.8: 404 `KeyNotFound`, 400 `InvalidAlgorithm`/`InvalidValue`/`InvalidParameter`, 403 `UnauthorizedAttestation`/`TokenReplay`, 400 `KeyNotExportable` — matches real `KeyVaultError`/`Error{code,message,innererror}` shape (innererror unmodeled) |
| 2 | Encrypt/decrypt response `{kid, value}` (KeyOperationResult) | PARTIAL | `key_vault_actions.ex` (do_encrypt/do_decrypt). Probe C2.2/C2.3: `{value, kid}` (+ smalt-only `alg` echo; oct adds `iv`/`tag` per A256GCM). `value`/`iv`/`tag` are base64url (row 2b fixed); smalt-only `alg` echo remains the PARTIAL residue |
| 2a | AAD support for A256GCM | GAP | `key_vault_actions.ex` aes_gcm_encrypt hardcodes AAD `""`; real KeyOperationsParameters/KeyOperationResult carry an `aad` field. Not modeled |
| 2b | `value` encoding: base64url wire form | CONFORMANT | `key_vault_actions.ex` b64url_encode/b64_decode: all `value`/`digest`/`signature`/`iv`/`tag` fields emit base64url without padding; inputs accept both base64url and standard base64 (compat). Fenced C2.2/C2.3/C2.5/C2.8 (no `=`/`+`/`/` in outputs; round trips) |
| 2c | sign/verify parameter contract | CONFORMANT | `key_vault_actions.ex` sign_digest/verify_signature: sign takes `digest` (base64url SHA-256) natively (compat: `value` pre-image digested server-side); verify takes `digest` + signature-in-`value` (compat alias `signature`), response `{"value": bool}` (KeyVerifyResult) with `valid` kept as a compat alias. Fenced C2.5 |
| 2d | iv/tag echo on oct ops | CONFORMANT | Probe C2.3: server-generated 12-byte iv + 16-byte tag echoed on encrypt, consumed on decrypt; matches real KeyOperationResult iv/tag semantics for A256GCM |
| 3 | Alg names + per-kty gating (`RSA-OAEP-256`, `A256GCM`, `RS256`, `PS256`; mismatches → 400) | CONFORMANT | `key_vault_actions.ex:364-373`. Probe C2.4: `A256GCM` on RSA → 400 `InvalidAlgorithm`; `RS512` → 400 `InvalidAlgorithm`; missing alg → 400 `InvalidAlgorithm`; base64 failure → 400 `InvalidValue`. Names exactly match the real JsonWebKeyEncryptionAlgorithm / JsonWebKeySignatureAlgorithm enumerations for the supported subset |
| 4 | Release-policy op gate on crypto ops (`OperationNotAllowed`) | PARTIAL | `key_vault_actions.ex:179-204`. Probe C2.6: policy `["encrypt"]` permits encrypt, refuses sign/decrypt 400 `OperationNotAllowed`. Real Azure release policies gate release only, and do not restrict encrypt/sign; `OperationNotAllowed` is not a documented KV code on this surface. Defensible emulator extension, disclosed in the moduledoc |
| 5 | List `{value: [...]}` shape | PARTIAL | `key_vault_actions.ex:113-122`. Probe C2.7: `{"value": [...]}` with kid+attributes per entry. Real KeyItem carries only kid+attributes+tags+managed — smalt over-shares the full JWK (dev note); `nextLink` paging never emitted |
| 6 | Key create envelope (KeyBundle) | PARTIAL | `egress_router.ex:295-321`. Probe C2.1/C2.1b: `{kid, key{kty,kid,n,e}, attributes{enabled,created,exportable}, release_policy}`. Real KeyBundle adds `key.key_ops`, `key.key_size`, `tags`, and `attributes.exp/nbf/updated/recoveryLevel`; request `attributes`/`tags` are accepted then dropped (probe sent exp+tags, response omitted them) |
| 6a | `n`/`e` placeholder values | CONFORMANT | `egress_router.ex` jwk_for_kty: create generates a real 2048-bit RSA keypair at create, caches the DER in the row (`key_material`, never projected), and emits a real JsonWebKey: `n` = base64url modulus (256 bytes decoded), `e` = `"AQAB"`; oct keys carry `k` = base64url derived material (dev-material derivation, row 18). Fenced C2.1c | |
| 6b | Versioned kid + versions listing | PARTIAL | create mints `kid = .../keys/{name}/{unique_integer}` (`egress_router.ex:302`); `list_versions/1` returns the single current version (`key_vault_actions.ex:130-135` — one row per name, no real version history; extension seam documented in the moduledoc) |
| 7 | Release request contract (`target`/`enc`/`nonce` body) | GAP | Real KeyReleaseParameters: `{target: <attestation assertion>, enc: CKM_RSA_AES_KEY_WRAP/RSA_AES_KEY_WRAP_256/384, nonce}`. Smalt (`skr.ex:86-123`, `egress_router.ex:330-336`): reads the MAA token from `Authorization: Bearer`, ignores the body entirely; `nonce` freshness and `enc` algorithm choice unmodeled (recipient wrap is fixed RSA-OAEP-256) |
| 8 | Release response `{value}` (signed object containing the released key) | GAP | Real KeyReleaseResult: `value` is a signed object containing the KeyBundle + release_policy (see the release doc's decoded example). Smalt returns derived material `{value, kid, keyMaterialVersion, policyHash, status: "Released"}` — no signed-object semantics, smalt-extra fields |
| 9 | Release policy schema | CONFORMANT | `egress_router.ex` validate_release_policy/policy_has_claim?: the real Azure grammar (`anyOf`/`allOf`/`claim`/`equals`, nested, `version`/`contentType` siblings) is accepted and stored verbatim (fenced C2.6b: anyOf policy → 200, stored verbatim, SKR release succeeds against it); validation is minimal-by-design (some claim/equals assertion or explicit `allowed_operations` list must exist, else 400 `InvalidParameter`). Smalt's `allowed_operations` gate extension (row 4) unchanged |
| 10 | SKR admission: exportable+policy required | CONFORMANT (by design) | `skr.ex:67-81`: key without `release_policy` → 400 `KeyNotExportable` (probe C2.8 leg 1). Real KV likewise requires an exportable key + keys/release permission; `KeyNotExportable` is a real KV error spelling (export REST surface) |
| 11 | SKR attestation binding (MAA) | CONFORMANT (dev-mode documented) | `skr.ex:86-112`. Probe C2.8: real RS256 MAA JWT via Bearer verified, `x-ms-compliance-status == "azure-compliant-cvm"` enforced (else 403 `UnauthorizedAttestation`); legacy raw-header path only behind `:skr_allow_legacy_header`. Release material is HKDF-derived, not the stored key — see disclosures |
| 12 | jti single-use replay refusal | CONFORMANT (by design) | `skr.ex:130-148`: `x-ms-runtime.jti` consumed atomically (ETS `update_counter` first-writer-wins); replay → 403 `TokenReplay`. Probe C2.8 leg 4: second release with the same token → 403 `TokenReplay`. Real KV/MAA instead offers a client `nonce` echo for freshness; `TokenReplay` is a smalt spelling |
| 13 | MAA claim surface vs real MAA | PARTIAL | `attestation.ex:42-58`. Probe C2.9: smalt's own MAA token still emits flat claims (`x-ms-attestation-type`, `x-ms-isolation-tee` flat string, `x-ms-compliance-status` top-level). Real MAA nests them inside the `x-ms-isolation-tee` OBJECT — SKR admission (`skr.ex` compliance_status/2) now accepts BOTH forms (fenced C2.9b: a real-shaped nested token passes release admission); the token-mint side (Security.Attestation, outside this surface) remains flat |
| 14 | TLS surface | CONFORMANT | Served through the same Bandit TLS twin as all data-plane routes; cert pin/hostname verification fenced by `test/kv_tls_test.exs`; C2 suite runs real TLS round trips for every row |
| 15 | Crypto correctness of the material | CONFORMANT (dev material) | RSA: 2048-bit pair generated once per name, DER cached in the row (`key_vault_actions.ex:222-233`); OAEP-SHA256, GCM tag 16B, RS256/PS256 sign+verify verified over the wire (C2.2/C2.3/C2.5) and in the unit suite (round trips, non-determinism, keypair caching) |
| 16 | wrapKey / unwrapKey | CONFORMANT | Same mechanics as encrypt/decrypt (`key_vault_actions.ex:77-82`); fenced at unit tier (`key_vault_actions_test.exs`). Not separately probed at wire tier — the route dispatches to the same code path C2.2/C2.3 fence |
| 17 | Error code spellings vs real service | PARTIAL | Real spellings: `KeyNotFound`, `KeyNotExportable`, `InvalidAlgorithm`/`InvalidParameter`/`InvalidValue` (real KeyVaultError `code` is free-form; these spellings appear in real service responses). Smalt-invented: `OperationNotAllowed` (crypto-policy gate), `UnauthorizedAttestation`, `TokenReplay` (release admission) — real service surfaces generic codes (e.g. 403 `Forbidden`) there; disclosed in the moduledocs |
| 18 | oct keys derived deterministically per name | BY DESIGN (dev material) | `key_vault_actions.ex:235`: `SHA-256("smalt-vault-derived:" <> name)`. Anyone knowing the naming scheme can re-derive the AES key without the vault; the `-HSM` suffix carries no HSM backing. Disclosed in the moduledoc; the most load-bearing deviation on this surface |
| 19 | Private material never leaves the vault | CONFORMANT | `public_record/1` drops `key_material` from listings (`key_vault_actions.ex`); the create and GET /keys/:name routes also project `key_material` out of the response (`egress_router.ex` create route + GET /keys/:name); release returns only derived material. Probe C2.1/C2.7 assert no `key_material` key in responses |
| 20 | `-HSM` kty suffix semantics | BY DESIGN gap (dev) | `RSA-HSM`/`oct-HSM` accepted and treated identically to soft kty; no HSM backing. Documented dev material derivation |

## Dev-material disclosures (by design, not gaps)

- **Derived oct keys** (row 18): deterministic per key name; no stored secret
  bytes. Documented in `KeyVaultActions` moduledoc.
- **Derived release material** (rows 11/12): HKDF-SHA256 over a per-VM master
  secret (or configured `:kv_master_secret`), salted by key name, bound to the
  release-policy hash — different keys/policies release different material,
  same key+policy is replayable-deterministic (fenced: C2.8b).
- **Attested-recipient binding** is dev-mode: with a `skr_recipient_jwk` RSA
  claim the material is RSA-OAEP-256-wrapped to the recipient; without one the
  material ships as plain base64 (`transport: "plain", mode: "dev"`).

## Highest-value fixes if the goal is real-SDK compatibility

1. Model the real release request/response contract: `target`/`enc`/`nonce`
   body and a signed-object `value` (row 7/8).
2. Add AAD support for A256GCM (row 2a).
3. Nest the MAA claims under `x-ms-isolation-tee` on the token-mint side
   (`Security.Attestation`, row 13) so smalt-minted tokens match the real
   shape; SKR admission already accepts both.
