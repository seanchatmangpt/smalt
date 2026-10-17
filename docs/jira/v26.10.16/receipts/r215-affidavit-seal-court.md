# r215 — affidavit seal-court witness receipt (lane 5 VERIFY; refreshed by lane 4 WITNESS)

- **Date**: 2026-10-16
- **Lane**: lane 5 (VERIFY), affidavit-closure wave, repo `/Users/sac/smalt`, `MIX_BUILD_ROOT=_build-lane623`; **refreshed by lane 4 (WITNESS) of the v26.10.16 finish wave**, `MIX_BUILD_ROOT=_build-lane632`
- **Standing**: **WITNESS-PENDING** (PARTIAL_ALIVE) — unchanged. The full ladder is now stably green on a quiet tree (2× 120/0, DEF-1 repaired) but the upstream ML_DSA65 gap is unchanged, so KD-89 stays **witness-PENDING, not PASS** per the amended close condition in `docs/jira/v26.10.16/WRAP_LEDGER.md` (PQC attestation-debt closure section).
- **No lib/ edits made by either lane.** One scratch probe test file was created and deleted in the same session (`test/lane623_scratch_probe_test.exs`, used to prove the engine start chain is healthy outside ExUnit; not present on disk at receipt time).

## Lane-4 (WITNESS) refresh — 2026-10-16 ~16:03, quiet tree

Lane 4 of the finish wave re-ran the full ladder after lanes 1-3 landed (probe `MIX_BUILD_ROOT=_build-lane632 mix compile` green before dispatch; failclosed test file and `gates/appconfig_etag_cas_gate.py` mtimes 15:58/16:00, no `lib/`/`test/` mtimes advanced during the runs).

### Final ladder counts (real output, one run; lane-4 replay command at the end of this section)

```
MIX_BUILD_ROOT=_build-lane632 mix test test/affidavit_wasm_engine_test.exs test/affidavit_seal_test.exs test/affidavit_wasm_failclosed_test.exs test/affidavit_ocel_emit_test.exs test/affidavit_ingestion_functor_test.exs test/trust_profile_test.exs test/smalt_affidavit_wasm_test.exs test/smalt_native_hcl_ladder_test.exs test/enclave_doctor_severity_test.exs test/enclave_doctor_env_test.exs
...
Finished in 5.2 seconds (0.00s async, 5.2s sync)
120 tests, 0 failures
```

**Quiet-tree stability: two consecutive runs, 120 tests / 0 failures each, same build root `_build-lane632`, minutes apart** (run 1 seed n/a, run 2 seed 754370 — different shuffle, same result). The run-3-green / run-4-failure pattern from the lane-5 window did not recur.

### DEF-1 resolution note

DEF-1 is **repaired on disk by lane630** (not this lane; no lib/ edits by lane 4). `lib/smalt/affidavit/wasm_engine.ex` now preserves the init refusal verbatim instead of collapsing it: `unavailable/1` `Logger.warning("Smalt.Affidavit.WasmEngine unavailable; init reason: #{inspect(reason)}")` + `:persistent_term` `last_init_refusal/0` / `reset_last_init_refusal/0` seams, typed `{:error, :engine_unavailable}` caller contract intact. Non-vacuity fence added: `test/affidavit_wasm_failclosed_test.exs` fence 9 (`@tag :lane630`, "fence 9: init fault keeps typed contract and preserves the real reason") — a forced bogus-path init fault must both keep the typed contract and advance the recorded reason past a `:none` baseline. Ladder output during this refresh exercised the seam live:

```
16:03:04.029 [warning] Smalt.Affidavit.WasmEngine unavailable; init reason: :artifact_missing_or_admission_failed
```

### DEF-2 / DEF-3 / flake adjudications

Lane 2's flake-adjudication receipts **do not exist at receipt time** (`ls -lt docs/jira/v26.10.16/receipts/` newest entry 15:59 INDEX.md; no lane-2 receipts on disk). No adjudication is fabricated here. DEF-2 (`appconfig-etag-cas` gate) had its gate file refreshed on disk at 16:00 by another lane — outcome un-adjudicated by lane 4. DEF-3 (NativeHclLadder fence-3 cross-lane failure) did not recur in either quiet-tree run; un-adjudicated.

### Lane-4 replay (10 files, adds `test/enclave_doctor_env_test.exs` over the lane-5 set)

```bash
MIX_BUILD_ROOT=_build-lane632 mix test test/affidavit_wasm_engine_test.exs test/affidavit_seal_test.exs test/affidavit_wasm_failclosed_test.exs test/affidavit_ocel_emit_test.exs test/affidavit_ingestion_functor_test.exs test/trust_profile_test.exs test/smalt_affidavit_wasm_test.exs test/smalt_native_hcl_ladder_test.exs test/enclave_doctor_severity_test.exs test/enclave_doctor_env_test.exs
```

### Pin state (re-verified this refresh, verbatim)

```
$ cat priv/wasm/affidavit.sha256
9b2908e4578720c453e6ef65649588cd7a3a5c64e45be97be613b7c154811413  affidavit_wasm.wasm
$ shasum -a 256 priv/wasm/affidavit_wasm.wasm
9b2908e4578720c453e6ef65649588cd7a3a5c64e45be97be613b7c154811413  priv/wasm/affidavit_wasm.wasm
$ grep @artifact_sha256 lib/smalt/affidavit/wasm_engine.ex
@artifact_sha256 "9b2908e4578720c453e6ef65649588cd7a3a5c64e45be97be613b7c154811413"
```

## Pin state (original lane-5 check, verbatim)

Lane-1 consolidation is consistent on disk:

```
$ cat priv/wasm/affidavit.sha256
9b2908e4578720c453e6ef65649588cd7a3a5c64e45be97be613b7c154811413  affidavit_wasm.wasm
$ shasum -a 256 priv/wasm/affidavit_wasm.wasm
9b2908e4578720c453e6ef65649588cd7a3a5c64e45be97be613b7c154811413  priv/wasm/affidavit_wasm.wasm
$ grep @artifact_sha256 lib/smalt/affidavit/wasm_engine.ex
@artifact_sha256 "9b2908e4578720c453e6ef65649588cd7a3a5c64e45be97be613b7c154811413"
```

Sidecar == artifact bytes == module-attribute fallback. No pin mismatch; no poll-cycle wait was needed.

## Verification ladder (9 files, exact command embedded)

```bash
MIX_BUILD_ROOT=_build-lane623 mix test test/smalt_affidavit_wasm_test.exs test/smalt_native_hcl_ladder_test.exs test/affidavit_seal_test.exs test/affidavit_wasm_engine_test.exs test/affidavit_wasm_failclosed_test.exs test/affidavit_ocel_emit_test.exs test/affidavit_ingestion_functor_test.exs test/trust_profile_test.exs test/enclave_doctor_severity_test.exs
```

Verbatim summaries of four runs, same build root, same file list (runs 1–3: 113 tests; run 4: 117 tests after a sibling lane landed shared test files mid-lane):

- Run 1: `113 tests, 6 failures`
- Run 2: `113 tests, 5 failures`
- **Run 3: `113 tests, 0 failures`** (green witness run; the run receipted here)
- Run 4 (minutes later, after another wave lane landed shared test files — test count moved 113→117 mid-lane): `117 tests, 1 failure` — failure is in `Smalt.NativeHclLadderTest` "fence 3: re-plan / re-apply yields zero drift (idempotent apply)" (`test/smalt_native_hcl_ladder_test.exs:132`), a **different suite** not owned by this lane; concurrent-lane interference signature, not the affidavit surface.

### Flaky-run failure face (runs 1–2, verbatim shape)

All failures were the same class: `assert {:ok, pid} = start` receiving `{:error, :engine_unavailable}` in `Smalt.Affidavit.WasmEngineFailClosedTest` positive-start fences (fences 2, 3, 5, 6, 7; fence 8 in run 1). Real failing assertion, run 1:

```
  4) test fence 2: oversized payload refuses typed, engine still serves (Smalt.Affidavit.WasmEngineFailClosedTest)
     test/affidavit_wasm_failclosed_test.exs:126
     match (=) failed
     code:  assert {:ok, pid} = start
     left:  {:ok, pid}
     right: {:error, :engine_unavailable}
```

Run 2 failure set: fences 5, 7, 3, 6, 2 — same class.

### Non-vacuity of the failure (not the engine, not the artifact)

The engine start chain is healthy outside the flaky window, witnessed directly:

```
$ MIX_BUILD_ROOT=_build-lane623 mix run --no-start -e '<replicate init chain>'
compile ok
imports: %{"af_abi_version" => ..., "af_alloc" => ..., "af_call" => ..., "af_free" => ..., "affi_admit_and_seal" => ..., "memory" => ...}
abi: {:ok, [1]}
```

20/20 rapid start/stop lifecycles in `mix run` succeeded (stress loop). The flake manifests only under ExUnit lifecycle churn — **typed defect DEF-1 below**.

## Seal-path evidence

- **CTRT 352B**: `test/smalt_affidavit_wasm_test.exs` tests 1–2 (352-byte CTRT, magic "CTRT", tariff LE-u64 round-trip at offset 167) and `test/affidavit_seal_test.exs` happy path — **green in all four ladder runs**, including both flaky runs. Pin-consistent engine admits and seals on the vendored artifact.
- **Verify-op court** (`test/affidavit_seal_test.exs:126` "round-trip: chain-sealed receipt verifies via the engine verify export", engine live via `start_supervised!(WasmEngine)` in setup): positive KAT — `verdict["accepted"] == true`, `profile == "CoreV1"`; tamper flip — one flipped hex char in `chain_hash` → `accepted == false`, refused at stage `chain_integrity`. **Green in all four runs.** This is the classical (blake3 chain) verify path; see gaps below for the PQC face.
- **Forge rejections**: forged receipt (missing `standing` field) → typed `{:error, {:invalid_receipt, field}}` (`test/affidavit_seal_test.exs:82`), and OCEL forged-event drop (`{:ok, :dropped}`, `test/affidavit_ocel_emit_test.exs:66`). Both green in all four runs. **Mode disclosure**: the forged-receipt refusal is adjudicated host-side (host admission check in `lib/smalt/affidavit/seal.ex` before the engine `affi_admit_and_seal` export), with the engine live in the suite setup. The **engine-adjudicated PQC forge-verify court did NOT run** — it cannot yet: the upstream engine's `verify_signature` op supports only ES256/ES256K/Ed25519 and returns `unsupported_algorithm` for `ML_DSA65`.
- **Doctor**: `just doctor` → `[PASS] Smalt doctor diagnostic court passed.` (advisory: dev CA not in macOS System keychain — pre-existing).
- **Invariant gates** (`just invariant-gates` with dev env, receipts on disk under `tmp/invariant-gates/`):
  - PASS: `cosmos-etag-cas`, `blob-worm`, `ledger-chain`, `queue-capacity`, `lock-clamp`, `bounds` (6/7)
  - **FAIL: `appconfig-etag-cas`** — positive scenario: race winner attribution check failed (`"FAIL the 2xx racer's value is the stored one (got loser-was-here)"`, stored etag = sha of loser content). All 5 non-vacuity fixtures correctly REFUSE (gate not vacuous). Solo reruns of the gate hit `ConnectionResetError` during its private-port substrate boot (transient boot contention under concurrent lane builds). Typed as **DEF-2**; likely interaction with the 51 in-flight `lib/` edits from the wave, unattributed by this lane.

## Typed gaps (named, per WRAP_LEDGER honesty correction)

1. **ML_DSA65 verify op unsupported upstream** — `/Users/sac/affidavit/affidavit-wasm/src/signature.rs:29-55`; returns `unsupported_algorithm` for `ML_DSA65`. Real ML-DSA-65 math exists only in the CLI crate smalt does not mount.
2. **CTRT [240..352] zeroed** — the 112-byte `pqc_witness_signature` region serializes as zeros; `compiler_binary_digest` is a `0x5a` placeholder (`/Users/sac/affidavit/src/handlers.rs:336`, `wire_ctrt.rs:249,283,305`).
3. **Forge-rejection court mode**: ran **host-adjudicated refusal mode only** (forged receipt refused host-side with the engine live; engine-adjudicated verify flip exercised the classical chain path). The KD-89 close-condition court (ML-DSA-65 verify: forge-tampered rejected / honest accepted **by the engine**) did not run.

## Typed defects (no lib/ edits made)

- **DEF-1** — `WasmEngine.start_link/1` is nondeterministically `{:error, :engine_unavailable}` under ExUnit lifecycle churn (observed 5–6 of the failclosed positive-start fences failing in two of four full-ladder runs; 20/20 healthy in `mix run` stress; 0 failures in run 3). The init `{:stop, reason}` is collapsed to the opaque `:engine_unavailable` at `lib/smalt/affidavit/wasm_engine.ex:59-66`, so the true init reason is unobservable from the outside. Owner: WasmEngine lane (repair lane). Suggested repair shape (owner to decide): surface the init `{:stop, reason}` verbatim from `start_link` and/or add lifecycle serialization around `with_engine` restarts in `test/affidavit_wasm_failclosed_test.exs`.
- **DEF-2** — `gates/appconfig_etag_cas_gate.py` positive: race-winner value/etag attribution failed once and solo reruns hit substrate boot `ConnectionResetError`. Not vacuous (all mutants refused). Needs owner attribution (gate race vs. in-flight consolidation edits).
- **DEF-3** — concurrent-wave interference: shared test files changed under this lane mid-run (113→117 tests); the new `NativeHclLadderTest` fence-3 failure is in a sibling lane's surface. Attributed here only as a wave-level note.

## KD-89 disposition

KD-89 close condition (amended, WRAP_LEDGER): wasm artifact shipped + doctor OK + **engine-adjudicated forge-rejection court green with ML_DSA65 support upstream**. Current state: artifact shipped and pinned (digest above), doctor PASS, seal + classical verify-op courts green, forge rejection host-mode only, ML_DSA65 unsupported upstream. **KD-89 remains OPEN / witness-PENDING. Flip is registrar-owned via `scripts/kd_flip.py`; no flip performed by this lane.**

## Replay

```bash
MIX_BUILD_ROOT=_build-lane623 mix test test/smalt_affidavit_wasm_test.exs test/smalt_native_hcl_ladder_test.exs test/affidavit_seal_test.exs test/affidavit_wasm_engine_test.exs test/affidavit_wasm_failclosed_test.exs test/affidavit_ocel_emit_test.exs test/affidavit_ingestion_functor_test.exs test/trust_profile_test.exs test/enclave_doctor_severity_test.exs
```

## Standing scope

`docs/jira/v26.10.16/receipts/r215-affidavit-seal-court.md` itself is the standing artifact. The receipt is a real-run witness with real output embedded; the seal path, verify-op court, doctor, and 6/7 invariant gates are green with receipts on disk. **Post lane-4 refresh (2026-10-16 ~16:03)**: DEF-1 is repaired on disk with a non-vacuity fence, the full 10-file ladder is stably green (2× 120/0 on a quiet tree), and the NativeHclLadder DEF-3 cross-lane failure did not recur. Remaining open faces: the upstream ML_DSA65 verify gap (typed gap 1) and DEF-2 (`appconfig-etag-cas` gate), the latter's gate file refreshed by another lane but un-adjudicated by lane 4. **No PASS standing is claimed; KD-89 stays witness-PENDING.**
