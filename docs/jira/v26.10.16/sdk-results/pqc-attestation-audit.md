# PQC Attestation Audit — smalt (Agent 9, Ring 3)

Date: 2026-10-16 · Repo: /Users/sac/smalt · Subject: attestation / signature surface
Standing: **AUDIT_COMPLETE — GAP_TYPED, NOT_CLOSED**

## Verdict (front-loaded)

**The directive's premise is FALSE.** No FIPS 204 ML-DSA-65 / Dilithium-3
signed receipts exist anywhere in smalt (or in the sibling ex4pm evidence
store). What exists is a real but **classical-only** attestation surface:

| Surface | Algorithm | Module | Proof status |
|---|---|---|---|
| Ledger receipts (Confidential Ledger emulation) | SHA-256 Merkle chain + RS256 JWS per receipt | `lib/smalt/security/ledger_writer.ex`, `lib/smalt/security/receipt_signer.ex` | T1/T2/T3 run this audit |
| Attestation tokens | RS256 JWS + exp/nbf, alg-confusion safe | `lib/smalt/security/attestation.ex` (delegates to ReceiptSigner) | T2 class |
| ARM STS tokens | HS256 (Joken) | `lib/smalt/arm_gateway/router.ex:288,297,335` | same Joken path covered by `test/`; not re-proven here |
| Pack lock integrity | SHA-256 | `ggen_igniter.pack.lock` (`sha256 08a35148cf77…f4`) | recorded, not re-proven |
| ex4pm evidence store | SHA-256 digests + Merkle leaf hashes, **no signatures** | `/Users/sac/ex4pm/lib/ex4pm_evidence/engine.ex:52,258,263`, `capability_mesh.ex:30` | outside repo, not re-proven |
| PQC profile scaffolding | — (typed refusal) | `lib/smalt/trust_profile/trust_profile.ex` | T4 run this audit |

Two premise corrections against the directive: (1) **no BLAKE3 exists** — the
pack lock is SHA-256; (2) of the two surfaces the directive named (JWT HS256
STS, ledger Merkle chains), both exist and held under tamper.

## 1. What exists today — with real tamper-resistance proofs

All proofs executed in-process via
`MIX_ENV=test mix run /tmp/pqc_audit_tamper.exs` on the real modules (ephemeral
Store, per-run unique ledger name) — Chicago-style, no stubs. Embedded output
is byte-exact from the run:

```
T1_CHAIN_VALID=true
T1_TAMPER_DETECTED=true
T2_VALID_SIG=verified
T2_TAMPERED_SIG={:error, :bad_signature}
T2_FORGED_PAYLOAD={:error, :bad_signature}
T2_ALG_CONFUSION_REFUSED={:error, {:bad_alg, "HS256"}}
T3_DUP_REFUSED=REFUSED_409_LedgerItemAlreadyExists
```

### 1.1 Ledger Merkle chain (SHA-256)

`LedgerWriter` chains `merkle_root = sha256(prev_root <> data_hash)` with
genesis `prev_hash = 64×"0"`, serializes appends inside one critical section
(no fork under concurrency), and signs each receipt via `ReceiptSigner`.

- **T1_CHAIN_VALID** — three appended receipts re-derive client-side:
  `sha256(prev_hash <> data_hash) == merkle_root` for each, with correct
  `prev_hash` links including the 64-zero genesis.
- **T1_TAMPER_DETECTED** — a receipt whose `merkle_root` was flipped to
  64×"f" no longer re-derives: the chain gate math refuses it.

The persistent gate (`gates/ledger_chain_gate.py`) runs the same law against a
live substrate (append → client re-derivation → negative fixtures: broken
prev-link, wrong root, non-zero genesis, duplicate accepted, missing receipt,
each must refuse). Not re-run here — requires a booted substrate; the
in-process T1 proof covers the chain law itself.

### 1.2 Receipt signatures (RS256 JWS)

`ReceiptSigner` signs ledger receipts and attestation tokens as detached JWS
compact; `verify_token/1` additionally enforces `exp`/`nbf`.

- **T2_VALID_SIG** — a freshly signed token verifies.
- **T2_TAMPERED_SIG** — one appended byte to the signature →
  `{:error, :bad_signature}`.
- **T2_FORGED_PAYLOAD** — attacker claims swapped in, original signature kept
  → `{:error, :bad_signature}` (RSA verify binds the full signing input).
- **T2_ALG_CONFUSION_REFUSED** — an HS256-declared envelope is refused before
  any key material is touched: `{:error, {:bad_alg, "HS256"}}` (RFC 8725 §2.5).

### 1.3 Duplicate-content commit point

**T3_DUP_REFUSED** — re-appending identical contents →
`409 LedgerItemAlreadyExists`, so ledger history cannot be rewritten by
content replay.

### 1.4 PQC scaffolding is honest by construction

`Smalt.TrustProfile.profile(:pqc)` returns a typed refusal, proven live:

```
PQC_PROFILE={:refused, :PQC_NOT_PROVISIONED, "profile not provisioned in Smalt: no real ML-DSA/hybrid implementation exists here; the typed refusal is the integration of the profile scaffolding (pack ML-DSA-65 is aspirational)"}
```

`profile(:classical)` is the only admitted profile (RS256, `provisioned: true`);
`:hybrid` refuses symmetrically (`:HYBRID_NOT_PROVISIONED`).

## 2. The PQC gap — typed finding

**FINDING PQC-GAP-1 (typed, OPEN):** smalt's attestation surface is
100% classical (RSA-2048/RS256, HS256, SHA-256). No FIPS 204 ML-DSA-65 or
Dilithium-3 implementation, keypair, or signed receipt exists in `lib/`,
`mix.exs`, or any dependency. Search receipt: `grep -rniE
"dilithium|ml-dsa|ml_dsa|mldsa|kyber|post.quantum|pqc" lib/ mix.exs` → matches
only in `lib/smalt/trust_profile/trust_profile.ex`, where they occur inside
refusal messages declaring the capability absent. The `affidavit-trust-plane-pack`
names ML-DSA-65 but smalt never fakes it (`trust_profile.ex:12-15`: "No PQC is
faked").

Impact: receipts and attestation tokens are harvest-now-decrypt-later /
forge-later vulnerable in principle — an attacker capturing an RS256 receipt
today could forge the classical key if/when RSA-2048 falls; PQC-signed
attestation is the mitigation and is absent.

Close condition: a real ML-DSA-65 keypair provisioned in
`Application.get_env(:smalt, :receipt_signing_key)`-equivalent config, receipts
carrying ML-DSA signatures verifiable by an independent FIPS 204
implementation, and `TrustProfile.profile(:pqc)` flipping from refusal to
admitted — receipt-gated, not claim-gated.

## 3. Adoption path (concrete)

### 3.1 Hex/BEAM candidates for ML-DSA (evaluate before pinning)

| Candidate | Form | Notes / risk |
|---|---|---|
| `dilithium` (hex) | Erlang NIF over pqcrystals reference C | Dilithium-3 (pre-FIPS-204 round-3); NIF build adds platform matrix |
| `ml_dsa`-class pure-Elixir ports | pure BEAM | FIPS 204 exact, but pure-Elixir signing is slow; fine for receipt-rate volumes (ledger appends are low-rate) |
| Rustler NIF over Rust `ml-dsa` crate | Rust NIF | FIPS 204 exact, fast, matches smalt's pure-BEAM posture only partially; NIF supply chain to audit |
| `liboqs` binding | NIF over liboqs | Full PQC suite, heavy; overkill if ML-DSA-65 is the only target |

No candidate is admitted here — each requires a court run (sign → independent
verify → tamper refuse) before a KD row closes. Honest status: **evaluation
UNKNOWN, not selected**.

### 3.2 Integration points (the receipt emitters)

1. **`Smalt.Security.ReceiptSigner`** — add `sign_pqc/1` / `verify_pqc/1`
   beside the RS256 path; header `"alg" => "ML-DSA-65"`, key from
   `Application.get_env(:smalt, :receipt_signing_key_pqc)`. The existing
   alg-allowlist (`check_alg`) makes the extension safe: unknown algs already
   refuse.
2. **`Smalt.Security.LedgerWriter`** (receipt build, `signature =` line ~159)
   — emit dual signatures during transition: `signature` (RS256) +
   `signature_pqc` (ML-DSA-65). Client verifiers accept either-or-both;
   hybrid is the migration-safe posture.
3. **`Smalt.Security.Attestation.verify_token/1`** — accept ML-DSA-65
   attestation tokens once ReceiptSigner supports them.
4. **`Smalt.ARMGateway.Router` STS** — HS256 is symmetric and has no PQC
   successor in FIPS 204; migrate to ML-DSA-signed JWTs (or keep HS256 dev-only
   and PQC-sign the production profile). Note this requires an asymmetric
   profile change; scope separately.
5. **`Smalt.TrustProfile`** — flip `profile(:pqc)` from
   `refusal(:PQC_NOT_PROVISIONED)` to an admitted profile
   (`algorithms: ["ML-DSA-65"]`) only after a witnessed sign/verify/tamper
   court receipt postdates the flip (same receipt-gated law as kd_flip.py).

Sequencing: (a) admit a hex dep behind a court, (b) dual-sign in
LedgerWriter + ReceiptSigner, (c) TrustProfile flip receipt-gated, (d) KD row
for "ledger receipts classical-only" closes only on (c)'s receipt.

## Falsifiers for this audit

- The claim "no PQC exists" is falsified by producing any ML-DSA/Dilithium
  artifact in `lib/` or `deps/` — search receipt above shows none.
- The T1–T3 proofs are falsified if `gates/ledger_chain_gate.py` or
  `just invariant-gates` fails on a live substrate.

## Receipt

Commands: `MIX_ENV=test mix run /tmp/pqc_audit_tamper.exs` (exit 0);
`MIX_ENV=test mix run -e 'TrustProfile.profile(:pqc)'` (typed refusal
captured). Script retained at `/tmp/pqc_audit_tamper.exs` (scratch, untracked).
No substrate boot required; no git operations performed; no files under
`lib/` modified. Standing: audit honest, gap OPEN, nothing faked.
