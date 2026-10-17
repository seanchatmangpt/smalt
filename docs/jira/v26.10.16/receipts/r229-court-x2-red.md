# Court-x2 wrap runs 29–30 — RED, typed defect list (terminal auditor)

- Standing: **RED — no two-green** (run 29 `COURT_X2_RC` never emitted; run 30 `COURT_X2_RC=1`)
- Lane: Terminal auditor (lane 664), 2026-10-17, subject `/Users/sac/smalt`
- Witnesses: `tmp/court-x2-wrap-run29.log`, `tmp/court-x2-wrap-run30.log`
- No fixes applied (auditor lane).

## Run 29 (01:46–~01:56) — RED, both runs failed (correction to r226)

r226 records run 29.2 as "stale / no verdict". The full run 29.2 log
(`/tmp/smalt-court-x2.EvE5O5/run2.log`, deleted at wrapper teardown) shows
run 29.2 completed normally with **1 failure**:

    1 doctest, 7 properties, 2435 tests, 1 failure (43 excluded)
    error: recipe `test-offline` failed on line 85 with exit code 2

Run 29 failing sets:

- Run 29.1 (3 failures):
  - `test/amqp/management_rpc_test.exs:734` — batch-delete DLQ GAP-A2-07:
    `assert {:ok, _} = Smalt.Store.get(:smalt_sb_messages, {queue, 3})`
    got `:error` (message absent from store at readback)
  - `test/store_dets_test.exs:145` — StoreDets restore×insert_new churn:
    `GenServer.call(pid, :restore, 5000)` **EXIT time out**
  - `test/enclave_ocel_test.exs:52` — EnclaveOcel lifecycle: destroy stage
    `RuntimeError: LRO never reached terminal within 400 polls`
    (`lib/smalt/enclave/state.ex:171` `poll_loop/2`)
- Run 29.2 (1 failure):
  - `test/store_dets_test.exs:145` — StoreDets restore×insert_new churn:
    `GenServer.call(pid, :sync, 5000)` **EXIT time out** (same test as 29.1)

Run 29.1 and 29.2 failed on the SAME test (StoreDets) plus extra members in
29.1 — **non-shifting repeat within run 29**; the run-30 gate then fired the
shifting-failure detector across runs (see r226).

## Typed defect list

1. **StoreDets restore×insert_new churn — DetsMirror-adjacent, REPEAT (2/2 runs of 29), not typed-set** —
   `GenServer.call(..., :restore/:sync, 5000)` timeout under churn race
   (`test/store_dets_test.exs:145,181-222`). Failed both runs of run 29 with
   different call sites (`:restore` then `:sync`). Not in the dispatched typed
   set (Metadata-indexer FLAKE_SOLO, sweeper-GC FLAKE_SOLO, port-contention);
   this is the only non-solo residual and the primary suspect for the next
   repair lane. DetsMirror LANDED class must be checked against this witness.
2. **Sweeper-GC FLAKE_SOLO** — W3SessionOps batch-delete DLQ readback
   `:smalt_sb_messages` key absent (`management_rpc_test.exs:763`), consistent
   with the known message-sweep class (run 29.1 only).
3. **Metadata-indexer / LRO-load FLAKE_SOLO face** — EnclaveOcel destroy LRO
   400-poll exhaustion under court load (`enclave/state.ex:171`), run 29.1
   only. Same load/parallelism family as r224's FLAKE_SOLO classification.
4. **Run-30 shifting pair (FLAKE_SOLO, court-environment load class)** —
   EventGridTopicsArmTest readback merge ordering (`eventgrid_topics_arm_test.exs:302`,
   `["mix-eg1","mix-ce"]` vs `["mix-ce","mix-eg1"]`) in 30.1; QueueStoreTest
   R160b deferred duplicate-seq (`queue_store_test.exs:721`) in 30.2.
   Different tests per run → the gate's flake signature fired. Full detail in
   `r226-court-x2-run30-red.md`.

## Verdict

RED. No two-green receipt possible in this window; standing stays
PARTIAL_ALIVE. Typed-set items already LANDED classes showed no new
failures (sink isolation, mcp_wire, ERROR_CODES, port laws — zero hits).
Rerun `just court-x2` on a quiet tree; prioritize defect 1 (StoreDets
timeout repeat) for the repair lane.
