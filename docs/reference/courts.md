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
| `amqp_invariant_driver.exs` | AMQP invariants driver (Elixir .exs) |

Non-vacuity law: every gate's verdict must REFUSE a mutated observation; a
gate that cannot exit 1 is the failure. `just invariant-gates` runs the five
fail-closed gates.

## Shim courts (`scripts/shim_court/`, `just shim-court <name>` / `just shim-courts`)

Protocol: BASELINE (sha256) → BEFORE → SHIM (marker `SHIM-COURT` mandatory)
→ AFTER (the flip IS the non-vacuity proof) → RESTORE (sha256 byte-exact,
fail-closed). Exit 0/1/3; a skip is loud (`[SKIP] <reason>`). Courts
(`*_court.sh`, shared harness `lib.sh`):

amqp_framing, atom_bridge, blob_worm, blob_worm_arms, blocklist,
comp_whitelist, conftest_proc_guard, corpus_fence, dets_growth,
disposition_token, eh_batch, eh_mgmt, enclave_loop, etag_cas, ets_cleanup,
kv_challenge, ledger_chain, lock_clamp, orphan_token, queue_capacity, plus
witness modules (`amqp_witness.py`, `blob_worm_witness.py`,
`lock_clamp_witness.py`, `*.exs`).

KD-COVERS/SIM-PASS auto-flip: a shim landing in `lib/` carries
`# KD-COVERS: KD-nn`; `scripts/kd_flip.py --apply` flips the register row to
CLOSED-SIMULATED only when a PASS witness receipt postdates the shim mtime.

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
- `docs/verification/` (verification receipts tree)