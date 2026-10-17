# ggen affidavit-wasm projection plan (NEXT-WINDOW WORK ORDER — not implemented)

Standing: PLAN-ONLY. Per the projection-candidates convention:
defaults → provider matrix → cascade ordering stands; plan-only this window, no implementation.

## Context

The rust→wasm→elixir mounting pattern already exists as marketplace capital:
`rust-wasi-wasmex-pack` (rww:) — the same pack that generated affidavit-wasm's own
`ffi.rs` (W1 ABI survey). The smalt-side engine-mount/seal/witness surfaces should be
specified as ontology rows + queries + templates in `smalt-substrate-pack` following
rww's consumer-side conventions (config keys, admission/pin, typed-refusal vocabulary),
not as new hand-written residue.

## Pack-pattern → smalt-surface mapping

| smalt hand-written surface | pack pattern (canonical) | counterpart pack(s) |
|---|---|---|
| `lib/smalt/affidavit/wasm_engine.ex` config surface: `config :smalt, :affidavit_wasm_path` / `:affidavit_wasm_pin_path`, `@artifact_sha256`, `last_init_refusal/0` (persistent_term) | `rww:HostElixirModule` (otpApp, rootModule, artifactPath, executionTimeoutMs) + `rww:PipelineBinding` (packPrefix, maxRequestBytes, maxOutstandingBytes) + `wja:WasmModule` pin properties (crateName, exportPrefix, abiVersion, maxRequestBytes, maxJsonDepth, stackSizeBytes) | rust-wasi-wasmex-pack (canonical), beam4pm-wasm-engine-pack (`bpw:timeoutClass` rows), beam-wasmex-host-pack (deprecated predecessor) |
| artifact pin/digest admission (`@artifact_sha256` fallback + pin-file load + `:lock_drift`-class admission refusal) | `rww:otpApp` Application.get_env digest fallback + wja module pin properties + `GgenIgniter.PackLock` digest/pin flow (`mix ggen_igniter.pack.lock --path <pack> --pack smalt-substrate-pack` re-pin — the same lock/digest law the replay-identity test fences) | rust-wasi-wasmex-pack + ggen_igniter PackLock |
| `Smalt.Affidavit.Seal` refusal ladder (`:engine_unavailable` typed-verbatim on engine down; `{:seal_refused, code}` with `:malformed_sealed_output`, `{:malformed_engine_return, other}`; engine-down passthrough preserves the typed code) | `rv:RefusalClass` closed-enumeration rows with `rv:classKind` + totality gates (010_exactly_one_class, 040_totality, 060_a2a_wire_totality — every code resolves to a declared class, exactly one class per outcome) | refusal-vocabulary-pack (rv:), affidavit-trust-plane-pack (`ctp:CryptographicStanding` closed total order) |
| `Smalt.TrustProfile` witness contract (engine-sealed CTRT witness block, subject-bound, canonical `pqc_receipt` travels inside signed envelopes; typed refusals `:PQC_NOT_PROVISIONED` / `:HYBRID_NOT_PROVISIONED` / `:UNKNOWN_PROFILE`) | `ctp:CryptographicStanding` individuals (closed order 0..7) + `ctp:TrustPlanePolicy` + `ctp:SignatureAlgorithm`/`ParameterSet` (PQC standing vocabulary) | affidavit-trust-plane-pack (ctp:), evidence-standing-pack (es: standing individuals), standing-ladder-pack (gate `010_no_skipped_states.rq` over standing ladder) |

Profile admission law (pack pattern): ctp: typed-UNSUPPORTED law — "false = typed
UNSUPPORTED in this pack; consuming code must refuse, never fake" → maps 1:1 onto
`Smalt.TrustProfile.profile(:hybrid)` → `{:refused, :HYBRID_NOT_PROVISIONED}`.

## Ontology additions (smalt-substrate-pack ontology.ttl — named, NOT implemented)

### Classes

- `smalt:AffidavitWasmBinding` (rdfs:seeAlso `rww:PipelineBinding`) — links guest crate + host module.
- `smalt:AffidavitHostModule` (seeAlso `rww:HostElixirModule`) — carries otpApp, rootModule, artifactPath, executionTimeoutMs.
- `smalt:AffidavitGuestCrate` (seeAlso `rww:GuestRustCrate` / `wja:WasmModule`) — carries crateName, exportPrefix, abiVersion, maxRequestBytes, maxJsonDepth, stackSizeBytes.
- `smalt:SealRefusalClass` (seeAlso `rv:RefusalClass`) — closed enumeration over the Seal ladder.
  Individuals with `smalt:sealRefusalOrder` closed total order:
  `ENGINE_UNAVAILABLE` (0), `SEAL_REFUSED` (1), `MALFORMED_SEALED_OUTPUT` (2),
  `MALFORMED_ENGINE_RETURN` (3).
- `smalt:CryptographicStanding` (seeAlso `ctp:CryptographicStanding`) — closed enumeration
  mirroring the ctp: individuals exactly, order 0..7 with `smalt:standingOrder` +
  `smalt:wireVariant`:
  VALID (0), INVALID (1), EXPIRED (2), REVOKED (3), REPLAY_REJECTED (4),
  UNKNOWN_KEY (5), PROFILE_REFUSED (6), MALFORMED (7).
  Implementation law: re-read the live ctp: rows from
  `packs/affidavit-trust-plane-pack/ontology.ttl` at implementation time — never copy
  from this doc.
  Contract: `smalt:CryptographicStanding` is the projected source for the witness
  contract's witness-verdict surface; `Smalt.TrustProfile` refuses typed
  (`PROFILE_REFUSED`-class) when the witness block is absent or not subject-bound.
- `smalt:TrustProfilePolicy` (seeAlso `ctp:TrustPlanePolicy`) — profile admission matrix:
  `:classical` native, `:pqc` engine-witness-gated, `:hybrid` typed UNSUPPORTED.

### Properties

- `smalt:affidavitWasmPath`, `smalt:affidavitWasmPinPath` (seeAlso rww:artifactPath) —
  the `config :smalt, :affidavit_wasm_path` / `:affidavit_wasm_pin_path` keys.
- `smalt:artifactSha256` — the pin digest; consumed by the pin admission query and the
  PackLock digest law.
- `smalt:sealRefusalOrder`, `smalt:standingOrder`, `smalt:wireVariant`.

### Queries

- `queries/affidavit_binding.rq` — AffidavitWasmBinding/HostModule/GuestCrate rows.
- `queries/seal_refusals.rq` — SealRefusalClass closed enumeration, ORDER-BY-free
  (sorted at render time in the template, per the registry.ex.eex canonical-ordering law).
- `queries/trust_standing.rq` — trust standing + TrustProfilePolicy rows.

### Templates

- `templates/affidavit_engine_config.ex.eex` — projects the config-key surface
  (path/pin-path/digest) and the pin admission (digest match → admit; drift → typed
  refusal), following the rww HostElixirModule consumer-side convention.
- `templates/seal_refusal_ladder.ex.eex` — projects the typed refusal ladder as a closed
  enumeration module (totality gate: every outcome resolves to exactly one declared class).
- `templates/trust_profile_matrix.ex.eex —` projects the profile admission matrix
  (`:classical`/`:pqc`/`:hybrid` with typed UNSUPPORTED for :hybrid).

### Gates

- `gates/010_affidavit_pin_totality.rq` — every binding row carries a sha256 pin digest.
- `gates/020_seal_refusal_totality.rq` — every Seal outcome resolves to exactly one
  declared `smalt:SealRefusalClass`.
- `gates/030_standing_ladder.rq` — standing order is a closed 0..7 total order with
  no skipped states (pattern: standing-ladder-pack `010_no_skipped_states.rq`).

## What stays hand-written (explicit residue)

The engine GenServer body (Wasmex store/instance lifecycle, memory read/write, the
`af_*` FFI call choreography) has no pack counterpart for its imperative core; only its
config surface, pin admission, and refusal vocabulary get projected. That residue is
declared per the handwritten=irreducible-residue rule, to be named in a HANDWRITTEN.md
when the pack lands.
