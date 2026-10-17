# Receipt: KD-89 ML-DSA-65 closure — upstream rebuild, re-vendor, forge court

Standing: PASS (witness receipt — engine-adjudicated ML_DSA65 forge court, all stages green)

Date: 2026-10-17
Lane: KD-89 closure attempt (lane 666, `MIX_BUILD_ROOT=_build-lane666`)
Repo: /Users/sac/smalt; upstream /Users/sac/affidavit

## Chain

1. **Upstream rebuild** (`/Users/sac/affidavit` HEAD `a8c3c2b`, includes `a4b65c8`
   "feat(affidavit-wasm): PQC ABI surface", 2026-10-16 23:04 -0700):
   `cd affidavit-wasm && cargo build --locked --lib --target wasm32-wasip1 --profile wasm`
   -> `target/wasm32-wasip1/wasm/affidavit_wasm.wasm`.
   Reproducibility (docs/WASM.md two-target-dir): second build into `target-repro`
   -> `cmp` exit 0, byte-identical. New digest + size:
   - sha256 `b3cf38bab02bdf2451122d01609fba4804eb452be49e8d217d597d4af8d1a967`
   - 716492 bytes
   Strings check: artifact contains `pqc_verify`/`pqc_assemble` symbols and
   `pqc_refused` error code.
   Pin refresh per `.claude/agents/wasm-abi-guard.md`: `registry/ARTIFACTS.sha256`
   wasm line + `registry/artifact-pin.json` (sha256/bytes) updated to
   b3cf38ba…/716492; enforcement harness
   `AFFIDAVIT_WASM=… cargo test --test registry_artifacts` -> 3 passed / 0 failed.
   `dist/affidavit_wasm.wasm` + `dist/affidavit_wasm.wasm.sha256` refreshed.
2. **Re-vendor to smalt**: copied to
   `/Users/sac/smalt/priv/wasm/affidavit_wasm.wasm` (sha256 b3cf38ba…, 716492 bytes)
   + sidecar `priv/wasm/affidavit.sha256`;
   `scripts/affidavit_wasm_build.sh --verify` ->
   `[affidavit-wasm] PASS: sha256 byte-exact` (exit 0).
   `@artifact_sha256` in `lib/smalt/affidavit/wasm_engine.ex` re-pinned to
   b3cf38ba… (the mount lane's pattern).
3. **Forge court** (smalt, `MIX_BUILD_ROOT=_build-lane666`, real engine boot +
   `WasmEngine.call_json/1`):
   - KAT positive (honest signature, msg "smalt-kd89-probe", fixed-seed
     ml_dsa::SigningKey<MlDsa65>, pk 1952 B / sig 3309 B encoded per
     affidavit-core `ExternalMlDsa65`):
     ```
     ENGINE STARTED
     PQC_VERIFY KAT  => {"accepted":true,"algorithm":"ML-DSA-65","ok":true,"op":"pqc_verify","profile":"pqc(ml-dsa-65)"}
     ```
   - Forge/tamper refusal (first 100 bytes of sig zeroed):
     ```
     PQC_VERIFY TAMPER => {"accepted":false,"algorithm":"ML-DSA-65","ok":true,"op":"pqc_verify","profile":"pqc(ml-dsa-65)","refusal":"ml_dsa65_rejected"}
     ```
   - Premise correction (typed, court-pinned): `verify_signature` with
     `alg=ML_DSA65` is an *intentional* typed refusal upstream:
     ```
     VSIG ML_DSA65 => {"ok":true,"op":"verify_signature","refusal":"unsupported_algorithm: `ML_DSA65`; supported: ES256, ES256K, Ed25519","valid":false}
     ```
     Upstream design routes PQC through the dedicated `pqc_verify`/`pqc_assemble`
     ops (src/pqc.rs); a court in affidavit-wasm `src/signature.rs`
     (`unsupported_and_mismatched_algs_are_typed`) pins the refusal. The KD-89
     row's "verify_signature returns unsupported_algorithm" is upstream-by-design,
     not a divergence to fix. The engine-adjudicated ML_DSA65 forge court runs
     through `pqc_verify`.
4. **Suites** (lane 666):
   - `mix test test/affidavit_seal_test.exs test/affidavit_wasm_engine_test.exs
     test/affidavit_wasm_failclosed_test.exs test/smalt_affidavit_wasm_test.exs`
     -> `25 tests, 0 failures`
   - `mix test test/trust_profile_test.exs` -> `76 tests, 0 failures`
   - `just doctor` -> `[PASS] Smalt doctor diagnostic court passed.`
     (pre-existing keychain ADVISORY only).

## Falsifier status

KD-89 falsifier — "forge-tampered ML-DSA signature rejected by the wasm engine
court, honest signature accepted" — witnessed above through the real engine
(`WasmEngine.call_json` -> wasmi module -> `ExternalMlDsa65`). Witness receipt
mtime (this file, 2026-10-17) postdates the shim
`lib/smalt/trust_profile/trust_profile.ex` (2026-10-16 15:05), satisfying
kd_flip.py's receipt-newer-than-shim gate. Registrar may run
`scripts/kd_flip.py --apply` for KD-89.
