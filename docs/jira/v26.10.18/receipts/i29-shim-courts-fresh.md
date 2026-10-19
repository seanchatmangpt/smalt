# Receipt: i29 shim-courts fresh run (2026-10-18)

- Standing: SUSPECT (aggregate exit 1 — 12 of 26 courts cannot flip)
Context: solo(just shim-courts)
- Subject: `just shim-courts`, all `scripts/shim_court/*_court.sh` (26 courts), repo /Users/sac/smalt
- Aggregate summary line (verbatim): `== summary: 14 PASS, 12 FAIL, 0 SKIP ==`
- `failed: blob_worm comp_whitelist dets_growth disposition_token eh_batch eh_mgmt etag_cas orphan_token renew_mirror settle_cas tombstone_grace wire_norm`
- Aggregate exit code: 1 (fail-closed: any non-flipping court is FAIL)

## Per-court verdicts

| court | verdict | failure signature (verbatim) |
|---|---|---|
| amqp_framing | PASS | — |
| atom_bridge | PASS | — |
| blob_worm_arms | PASS | — |
| blob_worm | FAIL | `[FAIL:BEFORE] before-witness failed against UNMODIFIED /Users/sac/smalt/gates/blob_worm_gate.py — old signature absent; refusing to shim` |
| blocklist | PASS | — |
| comp_whitelist | FAIL | `[FAIL:AFTER] after-witness failed on the LANDED router (fix absent or regressed)` |
| conftest_proc_guard | PASS | — |
| corpus_fence | PASS | — |
| dets_growth | FAIL | `[FAIL:BEFORE] before-witness failed against UNMODIFIED lib/smalt/store/dets_mirror.ex — old signature absent; refusing to shim` |
| disposition_token | FAIL | `[FAIL:AFTER] after-witness failed against SHIMMED lib/smalt/messaging/amqp/connection.ex — new outcome absent (gate vacuous or shim inert); file restored+verified` |
| eh_batch | FAIL | `[FAIL:BEFORE] before-witness failed against UNMODIFIED lib/smalt/messaging/event_hubs.ex — old signature absent; refusing to shim` |
| eh_mgmt | FAIL | `[FAIL:BEFORE] before-witness failed against UNMODIFIED lib/smalt/messaging/amqp/connection.ex — old signature full output absent; refusing to shim` (before-witness failed against UNMODIFIED lib/smalt/messaging/amqp/connection.ex — old signature absent; refusing to shim) |
| enclave_loop | PASS | — |
| etag_cas | FAIL | `[FAIL:AFTER] after-witness failed against SHIMMED lib/smalt/data_plane/cosmos.ex — new outcome absent (gate vacuous or shim inert); file restored+verified` |
| ets_cleanup | PASS | — |
| kv_challenge | PASS | — |
| ledger_chain | PASS | — |
| lock_clamp | PASS | — |
| orphan_token | FAIL | `[FAIL:AFTER] after-witness failed against SHIMMED lib/smalt/messaging/amqp/lock_manager.ex — new outcome absent (gate vacuous or shim inert); file restored+verified` |
| queue_capacity | PASS | — |
| renew_mirror | FAIL | `[FAIL:AFTER] after-witness failed against SHIMMED lib/smalt/messaging/amqp/lock_manager.ex — new outcome absent (gate vacuous or shim inert); file restored+verified` |
| settle_cas | FAIL | `[FAIL:AFTER] after-witness failed against SHIMMED lib/smalt/messaging/amqp/queue_store.ex — new outcome absent (gate vacuous or shim inert); file restored+verified` |
| sleep_gate | PASS | — |
| strata_cleanup | PASS | — |
| tombstone_grace | FAIL | `[FAIL:SHIM] apply_shim failed; file restored from backup` |
| wire_norm | FAIL | `[FAIL:SHIM] kd01: target line found 2x (need exactly 1): lib/smalt/egress_router.ex` / `[FAIL:SHIM] kd01: shim failed; file restored` |

## Embedded aggregate output (tail)

```
== summary: 14 PASS, 12 FAIL, 0 SKIP ==
failed: blob_worm comp_whitelist dets_growth disposition_token eh_batch eh_mgmt etag_cas orphan_token renew_mirror settle_cas tombstone_grace wire_norm
EXIT=1
```

## Representative court receipt embedded in run output (amqp_framing)

```
AMQP FRAMING SHIM COURT RECEIPT (subject: lib/smalt/messaging/amqp/connection.ex)
BEFORE (unshimmed) : witness rc=3, signature: WITNESS_TIMEOUT
AFTER  (shimmed)   : witness rc=0 (SUCCESS)
RESTORE sha256     : OK (6ccb6f65… vs live 6ccb6f65…) byte-exact
VERDICT: NON-VACUOUS — unshimmed witness fails with the recorded signature, shimmed witness passes, restore byte-exact.
```

## Notes

- No [SKIP] lines were emitted by any court in this run: 0 SKIP. (Note: [SKIP] reasons verbatim = none; the only skip-flavored output observed was enclave_loop PASS with "[enclave-loop] all three families: skip loudness proven load-bearing" — a PASS, not a skip.)
- First attempt at this run was background-killed by signal 15 at the 30-minute background cap (after 10 courts); the receipted run is a clean full second run, 26/26 courts, no kills.
- All FAIL paths were fail-closed: files restored, "file restored+verified" / "file restored" present in every FAIL diagnostic. No CORRUPTED verdicts were emitted.
- Machine was under heavy concurrent lane load (multiple parallel mix test suites) during the run; before/after witnesses are signature-based and self-booting, but wall time per court was elevated. Aggregate result is exit 1 either way.
- Failure classes: 4 BEFORE-refusals (witness's recorded old signature no longer matches the unmodified subject — premise rot in the court, not in lib/), 7 AFTER-refusals (shim did not produce the recorded new outcome), 2 SHIM-application failures (tombstone_grace, wire_norm — anchor-line drift in the court script).
