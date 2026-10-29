# w6bc — KV key parity gaps (versions pagination, update attributes, AES-KW, randomnumbers)

**Standing:** ALIVE (module tier)
Context: solo
Date: 2026-10-20

## What landed

All additive to `lib/smalt/data_plane/key_vault_actions.ex` (landed rotation-policy/backup
clauses untouched) + additive wire faces in `lib/smalt/egress/KvRoutes.ex`:

1. **AES Key Wrap (RFC 3394/5649) family** — new `key_wrap/3` / `key_unwrap/3`
   dispatch: oct keys get A256KW/A192KW/A128KW via a pure-Elixir RFC 3394 core
   (`kw_wrap/kw_unloop`; OTP 28 :crypto has no :aes_kw cipher), the landed
   A256GCM oct face preserved (kw_alg_request? gate), RSA keeps the landed
   RSA-OAEP-256 wrap face. Public seam `aes_kw_wrap/2`/`aes_kw_unwrap/2` for
   direct callers.
   Wire: `kv_crypto_dispatch` wrapkey/unwrapkey arms now call key_wrap/key_unwrap.
2. **randomnumbers face** — `POST /keys/:name/randomnumbers` (literal route before
   the :action catch-all): length random bytes wrapped by the key per alg;
   oct+A256KW supported, key-size checks, length guard 16..128 multiple-of-8;
   RSA faces typed-UNSUPPORTED (typed 400 InvalidAlgorithm — documented choice).
3. **Versions pagination** — `list_versions_paged/2` (maxresults 1..25, $skip;
   off-past-end → []); the versions route body now parses maxresults/$skip via
   kv_page_param/4 (clamped, invalid → default).
4. **Update-key attributes face** — landed `update_key_properties` +
   PATCH routes witness-verified: enabled=false persists and echoes on the
   root record (W10/W11).

## Witness (real output, module-direct over real Store)

Replay: `MIX_BUILD_ROOT=_build-lane-w6bc MIX_ENV=test mix run --no-start tmp/w6bc_witness.exs`

```
W1_RFC3394_VECTOR=true
W2_UNWRAP_ROUNDTRIP=true
W3_KEY_CREATED=true
W4_KW_WRAP_ALG=true
W5_KW_WRAP_KID=true
W6_KW_ROUNDTRIP=true
W7_GCM_PRESERVED=true
W8_RANDOMNUMBERS_OCT=true
W9_RSA_TYPED_UNSUPPORTED=true
W10_ATTR_DISABLED=true
W11_ATTR_PERSISTED=true
W12_PAGINATION_COUNTS=true
W13_PAGINATION_DISJOINT=true
W14_PAGINATION_PAST_END=true
W6BC WITNESS: ALL LEGS DONE
```

## Falsifier

Re-running the witness with the t-counter or inverse-cipher bug present (or the
length-arg bug present) turns W1/W2/W6/W8 false — green under the broken core
would be vacuous. The RFC 3394 B.2 vector leg (W1) is the non-vacuity anchor:
it cannot pass unless the core implements RFC 3394 exactly.

## Integrity note (disclosure)

The w6i-class generation-corruption class hit this lane hard: 6+ corrupted
Edits/appends during the KW-core authoring (garbled clauses, mangled
placeholders like `NFC`: `, `transport`, `attempts => 0`, duplicated
crypto calls, an `End` capitalization slip, and one literal-vector byte slip
in the witness itself (`3` for `0x3E`)) — every one caught by per-chunk syntax
gates + the RFC-vector leg and repaired on disk; the final files are swept
clean (grep shows no placeholder tokens) and the tree compiles (0 diagnostics
in my two files). Sibling churn (quota_usage.ex, cosmos_consistency.ex, rbac.ex,
KvRoutes-by-siblings) rotated through the bounded polls; none of it mine.

No git operations. Build root `_build-lane-w6bc` left for coordinator lane-clean.
