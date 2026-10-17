# T5 Clean-Room Validation Receipt (lane 392)

- date: 2026-10-16
- lane: 392 (validation; ladder hardcodes lane 391 build root `_build-lane391`, ports 39390-39395)
- subject: `scripts/tf_cleanroom.sh` (landed 10:13 PDT), FR-6 `drop_account_data` in `lib/smalt/data_plane/blob_storage.ex`
- standing: **SUSPECT — FAIL (typed), BLOCKED-TRUST**. Ladder verdict FAIL (exit 1), reproducible at stage 3 apply.

## Executed

9 runs of `scripts/tf_cleanroom.sh` (5 with a BLOCKED-TRUST-patched copy, ROOT-pinned to
`/Users/sac/smalt`; original aborts at the trust gate). Gate was open at 10:13:
script present, `bash -n` clean, `drop_account_data` present in blob_storage.ex.

## Stage verdicts (best run: run9, 11:11-11:22 PDT)

| stage | verdict | note |
|---|---|---|
| preflight (tf binary, files, ports) | PASS | |
| stage1 fresh substrate (zero state) | PASS | 3.3s warm; zero-state witness resources GET = 0 pre-apply |
| stage1 TLS twin 39391 | PASS | |
| stage2 trust status gate | **BLOCKED-TRUST** | `tf_trust_setup.sh trust` needs interactive SecurityAgent approval — human gate, not automatable headless |
| stage2 lane env wiring | PASS | |
| stage3 tf init (offline mirror) | PASS | 33-70s; mirror dir churns (missing 3 of 5 runs — concurrent lane) |
| stage3 tf plan | PASS | 3 to add |
| stage3 tf apply | **FAIL (typed)** | 3 reproducible errors, see findings |
| stage4 zero-drift plan -detailed-exitcode | NOT REACHED | N/A this run — blocked at apply; last known value N/A |
| stage5 exs harness | NOT REACHED | |
| stage6 mjs console leg | NOT REACHED | |
| stage7 tf destroy (FR-6 cascade) | NOT REACHED | |
| stage8a subscription GET residue | NOT REACHED | |
| stage8b ETS identity gate | **PASS (standalone)** | `MIX_BUILD_ROOT=_build-lane391 MIX_ENV=test mix test test/smalt_ets_baseline_identity_test.exs` → 1 test, 0 failures; create+delete restores strict ETS identity |

`plan -detailed-exitcode`: **N/A** — stage 4 never reached; apply fails first.

## Typed findings for dispatch

1. **F1 (KD-class, lib)**: azurerm polls the emulator-returned `vault_uri`
   (`https://kv-smalt-fixture.vault.azure.net`) — real-internet DNS fail
   `no such host`. Emulator should return a loopback-reachable vault_uri.
   Surface: key vault ARM create response.
2. **F2 (KD-class, lib)**: `resourceManager` in `/metadata/endpoints`
   (`lib/smalt/arm_gateway/router.ex:1502-1503`) carries a trailing slash;
   go-azure-sdk concatenates → `https://localhost:39391//subscriptions/...`
   storage `listKeys` POST → "HTTP response was nil; connection may have
   been reset". Strip trailing slash (owning-lane edit; KD-COVERS token
   required).
3. **F3 (lib)**: azurerm 4.54 "Missing Resource Identity After Create" on
   storage account — emulator create response lacks the identity azurerm
   expects (`id`/identity block). Storage account create response shape.
4. **F4 (scripts)**: `scripts/gen_dev_cert.sh` idempotency defect — reuses a
   stale SELF-SIGNED leaf (`issuer=subject=CN=127.0.0.1`, no CA, missing/absent
   SAN risk) because it "reuses existing" without checking issuer==CA.
   Witnessed: leaf was self-signed; Go: `x509: "127.0.0.1" certificate is not
   standards compliant`. Repair applied this session: CSR re-signed by CA with
   SANs; chain verifies OK.
5. **F5 (scripts)**: `tf_cleanroom.sh` cleanup trap kills the subshell PID,
   not the beam — leaked substrate held 39390 after failed runs (needed manual
   sweep twice). Use a process-group kill or the substrate.sh lock manager.
6. **F6 (env)**: CA re-minted 3x mid-session by a concurrent lane (keychain
   fingerprint vs file DEAD-CA detection fired correctly); mid-run CA churn
   causes in-run TLS resets. Serialize cert minting per session.

## Repairs applied this session (validation lane, disclosed)

- `.smalt/tls/dev-cert.pem` re-signed from existing CSR by the repo CA with the
  script's SAN extfile (fixes F4's symptom; the script fix itself is dispatched).
- Manual `kill` of lane-port holders leaked by the harness (F5 symptom).

## Standing recommendation

SUSPECT (not ALIVE). T5 is one landing away: F2+F3 are small lib fixes, F1 is
the KD row; with trust granted via one interactive `scripts/tf_trust_setup.sh
trust` (click Always Trust) the ladder is expected full-green. Recommend:
(1) dispatch F1-F3 to the data-plane lane, F4-F5 to the tooling lane;
(2) Sean runs `scripts/tf_trust_setup.sh trust` once interactively;
(3) rerun ladder → expect v26.10.16 T5 milestone.
