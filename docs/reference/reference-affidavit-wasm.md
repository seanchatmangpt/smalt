# reference: affidavit-wasm

Reference for the affidavit-wasm seal surface in smalt: what the module
seals, how the artifact is built and pinned, the typed-refusal ladder,
the doctor check, and the test files.

## What it seals

`Smalt.Affidavit.Seal.admit_and_seal/2` takes a dfcm-receipt-shaped map
(the five R fields: `subject_sha`, `authority`, `consequence`, `replay`,
`standing`), canonicalizes it (sorted-key, compact JSON; RFC 8785 subset
for the ASCII field-name set), and hands the canonical bytes to the
affidavit-wasm engine's `affi_admit_and_seal` export. The engine seals a
CTRT token (deontic modality, tariff) and returns a sealed binary plus
content address; the host gets
`{:ok, %{sealed: binary, receipt: canonicalized_map}}`.

The sibling crate is `<affidavit-repo>/affidavit-wasm` (WASI
`wasm32-wasip1`, `wasi_snapshot_preview1` imports only). Doctrine:
certify, don't decide — the module checks a receipt against the format
standard, it never judges whether the work was honest.

## Build and pin

`scripts/affidavit_wasm_build.sh`:

```bash
./scripts/affidavit_wasm_build.sh           # build (if needed) + seed priv/wasm/
./scripts/affidavit_wasm_build.sh --verify  # re-hash vs priv/wasm/affidavit.sha256
```

- Exit 0 ok; 1 build/verify failure (fail closed); 3 loud SKIP when the
  environment is unmet (no cargo, no source crate, target not installed,
  or nothing seeded yet under `--verify`).
- Seeds `priv/wasm/affidavit_wasm.wasm` +
  `priv/wasm/affidavit.sha256`. Idempotent: a re-run byte-exactly
  reproduces the artifact or fails closed.
- `mix.exs` pins `{:wasmex, "~> 0.15.1"}` so graphlaw and affidavit
  share one wasmex identity.

## Config contract

```elixir
config :smalt,
  affidavit_wasm_path: "priv/wasm/affidavit_wasm.wasm",      # artifact
  affidavit_wasm_pin_path: "priv/wasm/affidavit.sha256"       # "HEX  name" file
```

The engine (and the doctor check) read these keys; the in-code defaults use
`priv/wasm/` paths, which match the seeded tree — no config is needed for the
default checkout. Override only when pointing at a different artifact/pin.

## Engine surface

`Smalt.Affidavit.WasmEngine` (GenServer, named singleton):

- `start_link/1` resolves the artifact, checks the sha256 pin, compiles
  the module, verifies imports are `wasi_snapshot_preview1` only and the
  required exports (`af_abi_version`, `af_alloc`, `af_call`, `af_free`,
  `affi_admit_and_seal`) are present, instantiates, and checks
  `af_abi_version == 1`. Any failure: `{:error, :engine_unavailable}` —
  never raises.
- `call/2` runs one JSON request through the linear-memory ABI:
  `af_alloc(len)` -> write UTF-8 JSON -> `af_call(ptr, len)` (packed
  `(out_ptr << 32) | out_len`) -> read `out_len` bytes -> `af_free`.
  Response is JSON: `{"ok":true,...}` or
  `{"ok":false,"error":{"code","message"}}`.
- `affi_admit_and_seal/1` seals a receipt from canonical JSON.

## Typed-refusal ladder

Every failure is a typed return — the engine never raises and never
fabricates a result.

| Condition | Return |
|---|---|
| Artifact absent, pin mismatch, bad ABI, bad request | `{:error, :engine_unavailable}` |
| Receipt map missing an R field | `{:error, {:invalid_receipt, field}}` |
| Engine refuses the receipt | `{:error, {:seal_refused, code}}` |
| Engine returns a malformed envelope | `{:error, {:seal_refused, :malformed_sealed_output}}` |
| `Smalt.TrustProfile.profile(:pqc)` with engine down | `{:refused, :PQC_NOT_PROVISIONED, msg}` |
| `Smalt.TrustProfile.profile(:hybrid)` | `{:refused, :HYBRID_NOT_PROVISIONED, msg}` |

The PQC fallback is honest: no real ML-DSA-65 implementation exists in
smalt; with the engine down the typed refusal IS the delivered behavior.
With the engine up, `profile(:pqc)` returns a witness-backed provisioned
profile (engine-sealed CTRT witness block). Note: the `algorithms`
label names the target algorithm only — the witness is the classical
CTRT seal (witness region [240..352] ZEROED upstream, no ML-DSA bytes;
engine verify is classical-only), NOT a PQC-sealed verdict.

## Doctor check

`Smalt.Enclave.Doctor` check 5 (`domain: "affidavit_wasm"`,
`check: "artifact_integrity_and_engine"`), surfaced via
`MIX_ENV=dev mix smalt.doctor`:

- PASS: artifact present, sha256 matches the pin, engine loads.
- WARN `AFFIDAVIT_WASM_DEGRADED`: artifact missing, pin missing, hash
  mismatch, or the engine refuses to start. Remediation row:
  `bash scripts/affidavit_wasm_build.sh`.
- FAIL `CHECK_ENGINE_CRASH`: the check itself crashed — a defect, not a
  seal verdict. The doctor task always exits 0; read the JSON.

## Test files

```bash
./scripts/fast_test.sh test/trust_profile_test.exs \
  test/affidavit_seal_test.exs test/affidavit_wasm_engine_test.exs \
  test/affidavit_wasm_failclosed_test.exs test/smalt_affidavit_wasm_test.exs
```

- `test/trust_profile_test.exs` — classical RS256 envelope path, typed
  PQC/hybrid fallback.
- `test/affidavit_wasm_engine_test.exs` — engine lifecycle, ABI ladder,
  export/import checks.
- `test/affidavit_seal_test.exs` — admit-and-seal contract, canonical
  JSON, refusal mapping.
- `test/affidavit_wasm_failclosed_test.exs` — crash ladder: corrupt
  artifact, oversize payload, concurrency, wrong hash.
- `test/smalt_affidavit_wasm_test.exs` — end-to-end seal round trip.

Observed 2026-10-16: `test/trust_profile_test.exs` -> `76 tests, 0
failures`. The `affidavit_*` files landed mid-window (the lane was still
iterating while this doc was written); standing at wrap is recorded in
`docs/jira/v26.10.16/receipts/`.

## KD register

`KD-89` in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`: without the wasm
engine, PQC verification stays the typed `:PQC_NOT_PROVISIONED`
refusal (`lib/smalt/trust_profile/trust_profile.ex`) rather than full
ML-DSA verification. Flip only via `scripts/kd_flip.py --apply`, gated on a
witness receipt newer than the shim.

## See Also

- [how-to-verify-pqc-seals.md](../how-to/how-to-verify-pqc-seals.md)
- `docs/PACK_INTEGRATION/trust-plane.md`
- `docs/WIRE_PARITY.md` (KD register pointer)
