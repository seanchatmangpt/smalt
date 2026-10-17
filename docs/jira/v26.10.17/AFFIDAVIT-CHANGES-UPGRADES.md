# AFFIDAVIT-CHANGES-UPGRADES — v26.10.17 (consumer transition guide for smalt)

Author: 18-lane consumer survey over `/Users/sac/smalt` (2026-10-17), consolidated
against affidavit branch `v26.10.16` at commit `f03b9e9` (CalVer 26.10.17). All 18
lanes complete; verdicts below are executed-or-inspected receipts, cited to their
lane. **No tag exists yet** — the release awaits operator sign-off; every pin below
is as-of the on-disk artifact.

## 1. TL;DR

The v26.10.17 wasm artifact (`681f7033…`, 718,736 B, 17 ops incl.
`smt_inclusion_verify`, **live-run inside smalt's real wasmex engine** — boots,
`af_abi_version()==1`, `capabilities` reports `version:"26.10.17"`, admit-and-seal
produced a valid 352-byte CTRT through smalt's own Chatman-invariant gate) is
**ABI-COMPATIBLE with zero smalt code changes required**. Consuming it is one
atomic three-file re-vendor transition. Two known smalt debts (KD-89 `ML_DSA65`
mismatch; one-op error-code awareness) are fail-closed today and become closable
after the refresh.

## 2. The one atomic transition (deployment-blocking)

| # | File | Change |
|---|---|---|
| 1 | `/Users/sac/smalt/priv/wasm/affidavit_wasm.wasm` | replace with `/Users/sac/affidavit/dist/affidavit_wasm.wasm` (`681f7033…`, 718,736 B) |
| 2 | `/Users/sac/smalt/priv/wasm/affidavit.sha256` | sidecar → `681f7033a78f31fcbbf7b7936a772ccac9c7da5f5d5d655bcea4a9e07bbaa8e8  affidavit_wasm.wasm` |
| 3 | `/Users/sac/smalt/lib/smalt/affidavit/wasm_engine.ex:60` | `@artifact_sha256` → same digest |

Then: `bash scripts/affidavit_wasm_build.sh --verify` (expect PASS), `mix test
test/smalt_affidavit_wasm_test.exs` (3/0 baseline), `just doctor` (or the doctor
mix equivalent) — engine must boot green. Doing any subset of the three files
leaves the engine refusing at boot (`artifact_digest_mismatch`, fail-closed —
verified live).

## 3. What v26.10.17 changes (verified on the live artifact)

### 3.1 ABI surface (additive)
- Ops 16 → **17**: new `smt_inclusion_verify` (the absence op's twin; honest
  witness admits, tampered cut/root refuse — ABI court
  `affidavit-wasm/tests/smt_inclusion_abi.rs`).
- Pin metadata now ontology-projected: 5 exports (`af_*` + `affi_admit_and_seal`)
  + 5 WASI imports (incl. `random_get`) — `artifact-pin.json` matches the bytes.
- Registry sha `c585d064…`; artifact sha `681f7033…` / 718,736 B.

### 3.2 Behavioral (semantic, all fail-closed)
- **JCS commitments are now domain-separated**: `op_jcs_canonicalize` keys
  commitments under `DOMAIN_TAG "affidavit.crypto-trust-plane.v1"` (not unkeyed
  blake3). Any external verifier comparing smalt's local canonicalization
  (`seal.ex:52-71`) against engine commitments must account for the tag.
- **Duplicate JSON keys now refuse** (`malformed`/`bad_json`) instead of
  last-win-silent — smalt's Elixir maps can't carry duplicates, so `seal.ex` is
  unaffected; external byte streams are.
- **Error surface unchanged in shape** (10 codes), but new typed refusal classes
  exist in root-crate modules smalt does not consume (zk-range/SMT/DQ gates).

### 3.3 smalt-side debts this release makes closable
- **KD-89 close-out**: `trust_profile.ex:702-722` sends `alg:"ML_DSA65"` to
  `verify_signature`, which supports only ES256/ES256K/Ed25519 → always
  `unsupported_algorithm` → `:PQC_NOT_PROVISIONED`. The new artifact ships the
  dedicated `pqc_verify` op (fields `op, msg/msg_hex, sig_hex, pk_hex, profile`;
  `pqc_verify` + `pqc_assemble` proven in the upstream KAT courts). Consumer fix:
  migrate the witness to `pqc_verify` — do NOT expect `verify_signature` to grow
  the alg.
- **Dead router fallback**: `arm_gateway/router.ex:2247-2255` builds a
  `{"op":"admit_and_seal",...}` JSON for `affi_admit_and_seal/1` — that export
  takes raw bytes, not JSON (inert today; silent-divergence hazard).
- **Error-code awareness**: smalt branches on 1 of 10 wire codes (`unknown_op`);
  the rest arrive as opaque binaries/`0xE001`. Fail-closed; a decode layer would
  make `pqc_refused` distinguishable from `bad_field` in the witness path.

## 4. Docs to update after the swap (all file:line verified)

- `README.md:13-26` — **highest priority**: the Standing block still claims
  "no ML-DSA-65 verify op / KD-89 OPEN" — both false since KD-89
  CLOSED-WITH-RECEIPT (2026-10-17) and `pqc_verify` shipped.
- `docs/reference/reference-affidavit-wasm.md:88-96`, `docs/how-to/how-to-verify-pqc-seals.md:65-72`,
  `docs/explanation/affidavit-evidentiary-design.md:172-203` — digest blocks
  citing `b3cf38ba…` (append-only correction style; do not rewrite receipts).
- `docs/reference/affidavit-wasm.md` typed-refusal ladder + op catalog — add the
  17th op + new refusal classes.
- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — add a row/note that the consumed
  ABI now exposes `smt_inclusion_verify` (unconsumed in lib/).
- `CHANGELOG.md` `[Unreleased]` — record the 26.10.17 consumption (pin bump,
  op surface, semantic changes above).
- Historical receipts (`kd89-ml-dsa-closure.md`, `WRAP_LEDGER.md`, `cap-affidavit-wasm.md`)
  — append-only witnesses; do not rewrite.

## 5. Opportunity (not required)

`smt_inclusion_verify` closes smalt's ledger trust gap: `ledger_writer.ex:140`
computes merkle roots in-process and no read path re-derives membership. Field
mapping is direct (`root_hex` ← merkle_root, `leaf_value_hex` ← data_hash,
`leaf_key_hex` ← tx_id-derived key). Two prerequisites: smalt's ledger chain is
SHA-256 (op is BLAKE3/monotree — needs a parallel monotree or an alg parameter
upstream), and no proof-generation source exists in smalt yet.

## 6. What needed nothing

- CLI surfaces (`cli/`, `smalt-cli/`): zero affi coupling — nothing to update.
- `workspace/`: zero affidavit references.
- OCEL flows: all UNAFFECTED (the new refusal gates are root-crate `core`-gated,
  absent from the wasm ABI).
- WASI import allowlist: both old and new modules import exactly the 5 allowed
  `wasi_snapshot_preview1` functions.
- `NOTICE.md`, `mix.exs` deps: no affidavit dep exists (vendored-copy model).

## 7. Prerequisite

The v26.10.17 tag does not exist yet (operator sign-off pending). smalt's re-pin
law wants a stable upstream subject — do the §2 transition after the tag lands,
pinning the tagged artifact's digest (re-verify `dist/` sha at that moment; the
current on-disk pin is `681f7033…` at affidavit `f03b9e9`+).
