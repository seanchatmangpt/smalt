# i29 shim-court verify receipt (repair lane IN-FLIGHT check)

- Standing: PASS (9/12) / FAIL (3/12) — repair lane NOT landed, per-court verdicts below
Context: solo (single lane, no concurrent workflows on the tree)

## Landing check

`docs/jira/v26.10.18/receipts/i29-shim-court-repair.md` does not exist;
`scripts/shim_court/` has 6 dirty files (dets_growth, disposition_token,
eh_mgmt, orphan_token, renew_mirror, settle_cas). Verdict: **[IN-FLIGHT]**,
so the 12 previously-failing courts were run individually, not the aggregate.

## Per-court verdicts (`just shim-court <name>`)

| court | verdict | note |
|---|---|---|
| blob_worm | PASS | AFTER flip witnessed; restore sha256 byte-exact |
| comp_whitelist | **FAIL:AFTER** | after-witness failed on LANDED `lib/smalt/egress_router.ex` (fix absent or regressed) |
| dets_growth | PASS | 200-vs-100 leak census flip witnessed |
| disposition_token | PASS | stale-token test FAILED under shim as required |
| eh_batch | PASS | KD-53 batch-split flip (rc=2) |
| eh_mgmt | PASS | KD-19 GAP-class flip (probe rc=1) |
| etag_cas | **FAIL:AFTER** | gate exited 0 under shim (wanted 1) against SHIMMED `lib/smalt/data_plane/cosmos.ex` — gate vacuous or shim inert; file restored+verified |
| orphan_token | PASS | R178j flip witnessed |
| renew_mirror | PASS | both subjects restored byte-exact (queue_store.ex co-subject) |
| settle_cas | PASS | R244 zombie flips witnessed |
| tombstone_grace | **FAIL:AFTER** | AFTER witness ran 0 tests, 0 failures (5 excluded) against SHIMMED `lib/smalt/messaging/amqp/sweeper.ex` — new outcome absent |
| wire_norm | PASS | kd03 BEFORE/RESTORE verified; ALL LEGS PASSED |

## Integrity

All courts that flipped verified sha256 byte-exact RESTORE (fail-closed);
the 3 FAILs also reported file restored+verified. No lib/ drift introduced
by this verification run.

## Command

```
just shim-court <name>   # x12: blob_worm comp_whitelist dets_growth disposition_token eh_batch eh_mgmt etag_cas orphan_token renew_mirror settle_cas tombstone_grace wire_norm
```

Falsifier for this receipt: rerun any court above; verdicts must reproduce.
Remaining work for the repair lane: comp_whitelist, etag_cas, tombstone_grace.
