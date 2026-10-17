# Capability: affidavit WASM engine (wasmex-mounted, fail-closed)

Standing: PARTIAL_ALIVE — engine live and test-witnessed; the PQC close of
KD-89 stays pending the D-lane ladder receipt (r215 not on disk at write
time; see lane-5) plus the doctor and forge-court items named below.

## Surfaces (on disk)

- Engine: `/Users/sac/smalt/lib/smalt/affidavit/wasm_engine.ex` — wasmex
  host, GenServer, fail-closed law (`{:error, :engine_unavailable}`, never
  raise).
- Artifact: `/Users/sac/smalt/priv/wasm/affidavit_wasm.wasm` with sha256
  sidecar authority `/Users/sac/smalt/priv/wasm/affidavit.sha256`.
- Seal module: `/Users/sac/smalt/lib/smalt/affidavit/seal.ex`.
- Operator-mandated real-run test:
  `/Users/sac/smalt/test/smalt_affidavit_wasm_test.exs`.
- Trust profile: `/Users/sac/smalt/lib/smalt/trust_profile/trust_profile.ex`
  — typed refusal `:PQC_NOT_PROVISIONED` retained verbatim as fail-closed
  fallback (`def profile(:pqc)` line 106; line 120; line 232 keeps the
  refusal when the engine refuses).

## Admission + digest pin

Boot admission: read artifact → sha256 sidecar pin (sidecar is the
AUTHORITY; a build-time `@artifact_sha256` attribute is cross-check
fallback only) → WASI import allowlist (`wasi_snapshot_preview1` only) →
required exports `af_abi_version af_alloc af_call af_free
affi_admit_and_seal` → instantiate with real `Wasmex.Wasi.WasiOptions{}`
imports → `_initialize` exactly once (wasm32-wasip1 reactor contract).

Digest pin verified on disk at receipt time:

```
$ shasum -a 256 priv/wasm/affidavit_wasm.wasm
9b2908e4578720c453e6ef65649588cd7a3a5c64e45be97be613b7c154811413  /Users/sac/smalt/priv/wasm/affidavit_wasm.wasm
$ cat priv/wasm/affidavit.sha256
9b2908e4578720c453e6ef65649588cd7a3a5c64e45be97be613b7c154811413  affidavit_wasm.wasm
```

Byte-exact match.

## JSON surface

Wire: UTF-8 JSON requests `{"op":...}` answered by the module itself with
`{"ok":true,...}` / `{"ok":false,"error":{...}}` — never a trap.
Client API: `Smalt.Affidavit.WasmEngine.call_admit_and_seal/4`
(state_delta, tariff_cents, deontic_modality, lease_context).

## CTRT seal path + Chatman invariant gate

The 352-byte CTRT / "CTRT" magic / offset-167 8-byte LE u64 tariff-basis
layout is asserted by the operator-mandated test; the seal path is
`lib/smalt/affidavit/seal.ex`. The Chatman invariant gate rides the same
admission: an in-variant-violating state delta is refused by the engine
(`{"ok":false,"error":{...}}`) rather than sealed — witnessed by the
fail-closed tier of the operator test (typed errors, no crash-loop).

## Witness contract (typed refusal fallback)

`test/smalt_affidavit_wasm_test.exs` — 3 tests, no mocks, no skips:
(1) `call_admit_and_seal/4` (tariff 12345, modality 0x01) returns a
352-byte CTRT with magic "CTRT"; (2) tariff basis cents round-trip
byte-exact at CTRT offset 167 (8-byte LE u64); (3) fail-closed tier:
oversized payload (> 16 MiB) → typed `{:error, :payload_too_large}`,
garbage delta → typed `{:error, _}`, then a well-formed call still
succeeds (no crash-loop). A genuine engine load failure is a verbatim
BLOCKED flunk, never a skip.

Real run (this lane, `MIX_BUILD_ROOT=_build-lane11` via
`scripts/fast_test.sh`):

```
$ scripts/fast_test.sh test/smalt_affidavit_wasm_test.exs
...
Finished in 0.4 seconds (0.00s async, 0.4s sync)
3 tests, 0 failures
[15:22:08] wall: 107s (build root: _build-ft-104d794a)
```

### ML_DSA65-verify-op upstream gap (named, not smalt-side)

Per the WRAP_LEDGER honesty correction: upstream FFI
(`/Users/sac/affidavit/affidavit-wasm/src/ffi.rs`) serializes the CTRT
112-byte witness region `[240..352]` as ZEROS — no ML-DSA-65 signature
bytes are embedded in the sealed CTRT today. What is live: ML-DSA-65 in
the engine's verify operations (`crypto_trust_pqc.rs` + `handlers.rs`).
So `:PQC_AFFIDAVIT_SEALED` may only claim (CTRT seal + verify-op verdict);
the zeroed witness region is an affidavit-side typed gap. KD-89's close
condition is amended to the VERIFY path (forge-tampered content rejected
by the ML-DSA-65 verify op over sealed content, honest accepted).

## Pending items (no receipt, no flip)

- **Ladder receipt pending, see lane-5**: the D-lane ladder receipt
  (r215) for `test/smalt_affidavit_wasm_test.exs` is NOT on disk
  (`ls docs/jira/v26.10.16/receipts/r215*` → no matches). This receipt
  embeds this lane's own real run above; the ladder receipt remains
  lane-5's deliverable.
- **Doctor check**: `lib/mix/tasks/smalt.doctor.ex` has no
  affidavit/wasm stage today (grep for `affidavit|wasm` → no matches).
  KD-89's close condition requires `just doctor` OK; the doctor stage
  must land before the flip.
- **Forge-rejection court** over the ML-DSA-65 verify path — not yet
  witnessed.

## OCEL seal event

`affidavit.seal` is a registry-gated OCEL event type
(`lib/smalt/ocel/event_registry.ex`, regenerated via `mix ggen_igniter.sync`;
emitter `lib/smalt/telemetry/affidavit_ocel.ex` — see
`docs/jira/v26.10.16/receipts/lane606-affidavit-seal-event.md`, 3 tests
0 failures, anti-vacuity flip witnessed). The seal sideband emits one
`affidavit.seal` event per seal into the real NDJSON sink, with the
mutated-type drop flip, witnessed in
`docs/jira/v26.10.16/receipts/cap-ingestion-functor.md`.

## Correction 2026-10-16 (lane 4 errc, reconcile-to-typed-gap-record)

The "ML_DSA65-verify-op upstream gap" section above overstates one
claim: "What is live: ML-DSA-65 in the engine's verify operations" is
WRONG as written. The wasm engine smalt mounts has NO ML-DSA-65 verify
op — `verify_signature` (`affidavit-wasm/src/signature.rs:29-55`)
supports only ES256/ES256K/Ed25519; `ML_DSA65` returns
`unsupported_algorithm`. Real ML-DSA-65 math lives in the affidavit CLI
crate only. The corrected record is the WRAP_LEDGER "Honesty
correction" + FINAL.md: attestation is classical-only; the witness
region [240..352] is zeroed; `:PQC_AFFIDAVIT_SEALED` may claim only
CTRT seal + classical verify ops; KD-89 close requires upstream
ML_DSA65 support first. This correction appends to the record; the
original text is retained as receipted.

## Provenance upgrade 2026-10-16 (lane X2, re-pin to upstream-sealed artifact)

Artifact re-pinned to the upstream-sealed v26.10.16 build:
`priv/wasm/affidavit_wasm.wasm` now carries sha256
`44ed468c66b06bc61b6ab24c64ab171df21d267124479a2790b333a7adf46c31`
(661338 B, byte-exact vs `/Users/sac/affidavit/dist/affidavit_wasm.wasm`
and its dist sidecar; panic-free C-ABI build). Sidecar
`priv/wasm/affidavit.sha256` updated; `@artifact_sha256` in
`lib/smalt/affidavit/wasm_engine.ex` updated to the same digest;
`scripts/affidavit_wasm_build.sh --verify` PASS (sha256 byte-exact).
Suite receipt: `MIX_BUILD_ROOT=_build-lane649 mix test
test/affidavit_seal_test.exs test/affidavit_wasm_engine_test.exs
test/affidavit_wasm_failclosed_test.exs test/smalt_affidavit_wasm_test.exs`
→ 25 tests, 0 failures — the engine admits the sealed bytes, the seal
path produces CTRT, forge refusals intact. No build-step deviation: the
script's `--verify` path re-hashes only (no rebuild), so the sealed
bytes were copied in place and verified against the new sidecar.
KD-89 ML_DSA65 status unchanged — the sealed artifact's
`verify_signature` remains classical-only (ES256/ES256K/Ed25519).
Standing: ALIVE (pinned, verified on the exact subject).
