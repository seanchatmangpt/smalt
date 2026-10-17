# How to verify PQC seals

How to confirm the affidavit-wasm seal path is live, and how to read the
typed-refusal ladder when it is not. Reference detail for the ABI, config
keys, and the build script lives in
[reference-affidavit-wasm.md](../reference/reference-affidavit-wasm.md).

## Prerequisites

```bash
rustup target add wasm32-wasip1   # once, for builds
cd <repo>
```

The engine loads the artifact from `config :smalt, :affidavit_wasm_path`
and its sha256 pin from `config :smalt, :affidavit_wasm_pin_path`.
Defaults and file locations: see the reference doc.

## Step 1: verify the artifact hash

```bash
./scripts/affidavit_wasm_build.sh --verify
```

Exit 0 = artifact matches the pin. Exit 3 = loud SKIP (artifact or pin
file absent — build first). Exit 1 = hash mismatch, fail closed.

Observed 2026-10-16:

```text
[affidavit-wasm] verifying <repo>/priv/wasm/affidavit_wasm.wasm
[affidavit-wasm] PASS: sha256 byte-exact
```

## Step 2: run the doctor check

```bash
MIX_ENV=dev mix smalt.doctor
```

Read the `affidavit_wasm` domain in the JSON receipt:

- PASS: artifact present, sha256 matches the pin, engine loads.
- WARN `AFFIDAVIT_WASM_DEGRADED`: one leg is missing (artifact absent,
  pin missing, hash mismatch, engine refuses to load). Aggregate becomes
  DEGRADED. Remediation: `bash scripts/affidavit_wasm_build.sh`.
- FAIL `CHECK_ENGINE_CRASH`: the check itself crashed; treat as a defect,
  not a seal verdict.

Exit contract: the task always exits 0 (WARN is not an error); read the
JSON, not the exit code.

## Step 3: exercise the PQC profile

In `iex -S mix`:

```elixir
Smalt.TrustProfile.profile(:pqc)
```

- `{:ok, %{profile: :pqc, algorithms: ["ML-DSA-65"], provisioned: true,
  witness: witness}}` — the engine is running and returned an engine-sealed
  CTRT witness block. The `algorithms` label names the target algorithm
  only: the witness itself is the classical CTRT seal (witness region
  [240..352] ZEROED upstream, no ML-DSA bytes; engine verify is
  classical-only), so this is NOT a PQC-sealed verdict.
- `{:refused, :PQC_NOT_PROVISIONED, msg}` — engine not running; the typed
  refusal is the honest fallback (KD-89). Nothing is faked.

Signing uses the same ladder: `Smalt.TrustProfile.sign/1` on a
`profile: :pqc` envelope attaches the engine witness when the engine is
up and returns the verbatim `:PQC_NOT_PROVISIONED` refusal otherwise.

## Test files

```bash
./scripts/fast_test.sh test/trust_profile_test.exs \
  test/affidavit_seal_test.exs test/affidavit_wasm_engine_test.exs \
  test/affidavit_wasm_failclosed_test.exs test/smalt_affidavit_wasm_test.exs
```

`test/trust_profile_test.exs` pins the classical profile and the typed
PQC fallback. The `affidavit_*` files pin the engine lifecycle, the seal
contract, and the crash ladder. Observed 2026-10-16 for the trust-profile
suite alone:

```text
76 tests, 0 failures
```

The `affidavit_*` files landed mid-window; consult the current window's
receipts (`docs/jira/v26.10.16/receipts/`) for their standing at wrap.

## KD register

`KD-89` (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`) tracks the PQC path:
without the wasm engine, PQC verification stays the typed
`:PQC_NOT_PROVISIONED` refusal rather than full ML-DSA verification.
Flips go through `scripts/kd_flip.py --apply` only.

## See Also

- [reference-affidavit-wasm.md](../reference/reference-affidavit-wasm.md)
- `docs/WIRE_PARITY.md` (KD register pointer)
