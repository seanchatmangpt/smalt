# Smalt Trust Plane — Pack Integration

Source packs:
`ggen-marketplace/packs/affidavit-trust-plane-pack` (CryptoProfile,
SignatureEnvelope, JCS) and
`ggen-marketplace/packs/aaif-profile-tailoring-pack` (closed-enum deployment
profiles).

Integration surface (all new files; no existing smalt code modified):

* `lib/smalt/trust_profile/trust_profile.ex` — `Smalt.TrustProfile`
* `lib/smalt/trust_profile/deployment.ex` — `Smalt.TrustProfile.Deployment`
* `test/trust_profile_test.exs`

## CryptoProfile standing (honest)

| Profile | Standing | What exists here |
|---|---|---|
| `:classical` | REAL, tested | RS256 (RSA-2048) signature over a JCS-canonical `SignatureEnvelope`; same key substrate as `Smalt.Security.ReceiptSigner` (app-env `:smalt, :receipt_signing_key`, else per-VM generated key cached in `:persistent_term`). The pack's Ed25519 path has NO Smalt counterpart — the classical profile here is RS256 only. |
| `:hybrid` | REFUSED typed | `{:refused, :HYBRID_NOT_PROVISIONED, msg}` |
| `:pqc` | REFUSED typed | `{:refused, :PQC_NOT_PROVISIONED, msg}` — the pack's ML-DSA-65 is aspirational upstream; Smalt does not fake PQC. The typed refusal IS the integration of the profile scaffolding. |

## SignatureEnvelope

Pack structure adopted: `version, algorithm, key_id, profile, policy_epoch,
revocation_epoch, generation, nonce (16B), not_before, expires_at,
subject_digest (32B), audience`. Per RFC-SA2A-007-errata E-E, algorithm,
key id and nonce live INSIDE the signed bytes; `verify/1` additionally
cross-checks the JWS header `alg`/`kid` against the payload-declared values
and refuses mismatch (alg-confusion safe: only exact `"RS256"` accepted).

Signing pre-image: JCS (RFC 8785 subset) canonical JSON of the envelope
document, with domain tag `smalt:trust-profile:v1` inside the signed bytes.

## Canonicalization: JCS vs the existing signer (pinned difference)

`Smalt.Security.ReceiptSigner` signs `Jason.encode!` of its claims map —
sorted-key JSON (Erlang term order = UTF-8 byte order) with Jason escaping
and number formatting. That is NOT full JCS (JCS sorts by UTF-16 code units
and mandates ECMAScript number formatting). Decision: the existing signer is
NOT modified; `Smalt.TrustProfile.jcs/1` owns a JCS subset for envelope
signing, and the test suite pins that for envelope-shaped documents (ASCII
keys, integer values) the two forms are byte-identical. Known subset
boundaries (documented in the module): integers beyond ±2^53 refused typed;
float formatting is shortest-round-trip, not full ECMAScript
`Number::toString` exponent brackets.

## Deployment profile tailoring (AAIF)

`Smalt.TrustProfile.Deployment` — closed enum `[:loopback_dev,
:sovereign_enterprise]`. `validate/2` is pure (profile, config) →
`{:ok, map}` / `{:refused, [{reason, detail}]}`:

* `loopback_dev` — admits any config, naming relaxations (anonymous auth,
  plaintext/auto TLS, absent shared key) as findings.
* `sovereign_enterprise` — requires `auth_mode == :enforce`, TLS enabled
  (`:auto` refused: self-signed dev cert), binary `sb_shared_key`.

`current_config/0` snapshots `:smalt, :auth_mode`, `:smalt, :tls`
(+ certfile fallback), `:smalt, :sb_shared_key` for doctor-style checks.

## Gate

```
mix test test/trust_profile_test.exs
mix test test/security/security_hardening_test.exs   # canary
```

Receipt: `docs/PACK_INTEGRATION/trust-plane.md` (this file); standing of the
pqc/hybrid refusals is REFUSED-BY-DESIGN, not BLOCKED — the refusal is the
delivered behavior.
