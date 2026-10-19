# courts

Admission courts: invariant gates and shim courts. Generated from the
directory surfaces (`gates/`, `scripts/shim_court/`).

## Invariant gates (`gates/`, exit 0 hold / 1 violated, fail-closed negative fixtures)

| gate | surface |
|---|---|
| `cosmos_etag_cas_gate.py` | cosmos etag compare-and-swap |
| `blob_worm_gate.py` | blob immutability/WORM hold |
| `ledger_chain_gate.py` | Confidential Ledger Merkle-chain continuity |
| `queue_capacity_gate.py` | queue capacity + max_body clamp |
| `lock_clamp_gate.py` | lock clamp |
| `appconfig_etag_cas_gate.py` | App Configuration etag CAS |
| `test_isolation_leak_gate.py` | test-isolation leak court (static scan: `Application.put_env` in `test/` without save-restore discipline) |

`test_isolation_leak_gate.py` is NOT one of the six `just invariant-gates`
gates: it runs via `just leak-court` / `just isolation-court`
(`justfile.d/25-leak-court.just`), fail-closed static scan with positive +
mutated-negative fixtures. `amqp_invariant_driver.exs` is not a gate: it is
the capture driver consumed by `gates/common.py` (~:274-293) to record AMQP
wire fixtures for the gate corpus. It has no independent exit contract.

Non-vacuity law: every gate's verdict must REFUSE a mutated observation; a
gate that cannot exit 1 is the failure. `just invariant-gates` runs the six
fail-closed gates (receipts `tmp/invariant-gates/<gate>-receipt.json`, six
written fresh).

## Shim courts (`scripts/shim_court/`, `just shim-court <name>` / `just shim-courts`)

Protocol: BASELINE (sha256) → BEFORE → SHIM (marker `SHIM-COURT` mandatory)
→ AFTER (the flip IS the non-vacuity proof) → RESTORE (sha256 byte-exact,
fail-closed). Exit 0/1/3; a skip is loud (`[SKIP] <reason>`). Courts
(`*_court.sh`, shared harness `lib.sh`):

amqp_framing, atom_bridge, blob_worm, blob_worm_arms, blocklist,
comp_whitelist, conftest_proc_guard, corpus_fence, dets_growth,
disposition_token, eh_batch, eh_mgmt, enclave_loop, etag_cas, ets_cleanup,
kv_challenge, ledger_chain, lock_clamp, orphan_token, queue_capacity,
renew_mirror, settle_cas, sleep_gate, strata_cleanup, tombstone_grace,
wire_norm — 26 court scripts (counted `ls scripts/shim_court/*_court.sh |
wc -l` on 2026-10-19) — plus witness modules (`amqp_witness.py`,
`blob_worm_witness.py`, `lock_clamp_witness.py`, `*.exs`,
`wire_norm_shim.py`). `sleep_gate_court.sh` is the NO-SLEEP-DOCTRINE Law 3
non-vacuity court (four legs: test, lib, burn-script, dual-injection).

KD-COVERS/SIM-PASS auto-flip: a shim landing in `lib/` carries
`# KD-COVERS: KD-nn`; `scripts/kd_flip.py --apply` flips the register row to
CLOSED-SIMULATED only when a PASS witness receipt postdates the shim mtime.

## Test-isolation courts

Beyond the invariant gates and shim courts above, the test-isolation
surface has its own courts (`justfile.d/25-leak-court.just`):

| court | surface |
|---|---|
| `just leak-court` | `gates/test_isolation_leak_gate.py` — static Application env / `:persistent_term` leak scan over `test/` |
| `just isolation-court` | `scripts/isolation_court.py` — static start_supervised!/put_env-restore discipline, inline `# isolation-court: exempt <reason>` only |
| `just isolation-court-runtime` | the same court with `--runtime-only`: boots the suite with `SmaltTest.IsolationFormatter` + `--max-cases 1` and diffs `Process.registered()` / `Application.get_all_env(:smalt)` per module; typed exemption registry `test/support/isolation_runtime_exemptions.exs` |

Contract, exemption law, and the async topology:
`docs/reference/test-isolation-law.md`. The sleep gate
(`scripts/sleep_gate.py`, `just sleep-gate`; non-vacuity
`just sleep-gate-court`) is a sibling enforcement surface — doctrine:
`docs/NO_SLEEP_DOCTRINE.md`, rationale: `docs/explanation/no-sleep.md`.

## Budget / burn / azsim court surfaces

Court-class surfaces that live outside `gates/` and `scripts/shim_court/`:

| surface | entry point | contract |
|---|---|---|
| budget gate | `just test-budget` (`justfile.d/28-test-budget.just`, manifest `test_budgets.json`) | fail-closed duration budget over named test files; fresh export required (`test-budget-seed` is a reviewed diff), gate refuses drift from the seeded manifest |
| burn suite | `just burn` + `burn-soak/-chaos/-matrix/-ring/-boot/-clean/-ocel` (`justfile.d/30-burn.just`) | boot/chaos/matrix/soak/summary stages; `burn-boot` row stops the line on `ORPHAN_LISTENER` / `ZOMBIE_BEAM` / `UNHANDLED_EXIT` |
| overlap court | `just overlap-court` (`justfile.d/30-burn.just`) | anti-vacuity court over scheduler overlap: a pass from a vacuous scheduler is the failure; serial/check/compare/report sub-recipes |
| azsim SDK court | `just azsim-sdk` (`justfile.d/14-sdk-matrix.just`) | azb20 headers via the recording proxy (`test/sdk-full/azb20/`); exit 0 = all cells pass-or-typed |
| HAVE self-check | `just have-self-check` + `just have-cycle` (`justfile.d/31-have.just`) | pool-saturation guard anti-vacuity: 15 fixture courts; a deficit without a typed `have_worker_fleet_active_count` alert row is the failure. Runbook: `docs/reference/have-runbook.md` |

## Config keys

None — the courts read no `Application.get_env` keys; they are external
processes over the substrate and the tree.

## Refusal vocabulary

Gates exit 1 with a printed verdict (refusal is the pass condition for the
negative fixture). Wire-level refusal codes the gates assert live in
`docs/ERROR_CODES.md` (`409 WriteConflict`, `409 ContainerLocked`,
`412 PreconditionFailed`, `409 LedgerItemAlreadyExists`).

## KD cross-links

The register's CLOSED-SIMULATED rows are the shim-court flip ledger; the
canonical table is `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (see
`docs/reference/kd-register.md` for counts and the flip path). The
comp_whitelist court closes GAP-AUD1-01 (a WIRE_PARITY gap token, not a KD
row). The AMQP atom-flood fence (D63/R95) is witnessed by
`test/amqp/fuzz_test.exs` and carries no KD row of its own.

## See Also

- `docs/reference/kd-register.md`
- `docs/reference/affidavit-wasm.md`
- `docs/reference/test-isolation-law.md`
- `docs/reference/burn-receipt-schema.md`
- `docs/reference/have-runbook.md`
- `docs/verification/` (verification receipts tree)