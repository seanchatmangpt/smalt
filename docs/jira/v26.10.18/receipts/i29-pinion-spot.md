# i29 — pinion spot-audit (6 highest-churn, post-AZB-06/07/10/22b)

Standing: PASS (6/6)
Date: 2026-10-18
Context: solo(read-only spot-audit at HEAD dda0bf5; no edits, no git ops)
Build root: `MIX_BUILD_ROOT=_build-ft-pa`. Subset of the 16-pin v-pinion-audit (pins 10-16 class).

## Method

Pin text verified by grep on the exact pinion lines, then owning suite executed.
All runs 2026-10-18 ~21:55-21:58 local.

## Per-pinion verdicts

| Pinion | Pin text (on disk) | Suite run | Result |
|---|---|---|---|
| KD-78 monotonic admission | `test/apiversion_matrix_test.exs:285` "admits monotonically (KD-78)" | apiversion_matrix | green (see combined run) |
| Refusal-tier law | `test/wire_tier_refusal_sweep_test.exs:111` "never 422, never 2xx" / InvalidResourceShape | wire_tier_refusal_sweep | green (see combined run) |
| WORM existence-scoped lock (KD-52) | `test/data_plane/blob_hardening_test.exs:132` "KD-52 WORM arms" + impl fence `lib/smalt/data_plane/blob_storage.ex:399` | blob_hardening | green (see combined run) |
| insert_new fresh-wins | `test/store_dets_test.exs:175` "insert_new :ok implies the FRESH value wins (no stale clobber)" | store_dets | green (see combined run) |
| InProgress-never-evicted | `test/lro_test.exs:617` "NEVER evicted at any age" | lro | green (see combined run) |
| Exactly-once s6 | `test/e2e/s6_checkpoints/checkpoint_chain.exs:139-142` `EXACTLY_ONCE_OK` / `zero_double_processing` | checkpoint_chain (mix run -- wins-dir) | exit 0, `verdict: EXACTLY_ONCE_OK`, `zero_double_processing: true` (200 events, 4 consumers, 2 partitions both exactly-once) |

## Executed command + output

```
MIX_BUILD_ROOT=_build-ft-pa mix test test/apiversion_matrix_test.exs \
  test/wire_tier_refusal_sweep_test.exs test/data_plane/blob_hardening_test.exs \
  test/store_dets_test.exs test/lro_test.exs
→ Finished in 14.1 seconds (0.00s async, 14.1s sync)
→ 404 tests, 0 failures (1 excluded)
→ exit 0

MIX_BUILD_ROOT=_build-ft-pa mix run test/e2e/s6_checkpoints/checkpoint_chain.exs -- /tmp/s6-pinion/wins
→ exit 0
→ RECEIPT:{"cas_successes_total":200,"consumers":4,"events_sent":200, ... 
   "partitions_report":[{part-0 exactly_once:true},{part-1 exactly_once:true}],
   "verdict":"EXACTLY_ONCE_OK","zero_double_processing":true}
```

## Verdict

6/6 pinions: pin text intact + owning suite green. 0 dropped, 0 regressions vs
the 16/16 baseline in `receipts/v-pinion-audit.md`. Errors: none.
