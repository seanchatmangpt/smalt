# i21d — Store-clear async race root cause + fix

Standing: PARTIAL_ALIVE (fix landed and witnessed; suite still carries a separate timing-flake face, fence-10)

Chain: `receipts/i21-full-suite-postfix.md` (run2 management_rpc batch-delete, run3 store_churn list_prefix, both solo-green) → this receipt.

## Audit (re-derived inventory, supersedes docs/TEST_ISOLATION.md's 24-file count)

`grep -rln 'Store.clear\|stop_store\|Lifecycle.stop' test/` → 66 files
(66th is `test/corpus/helper.exs`, whose `ensure_store/0` calls `Store.clear()`; it is
`Code.require_file`d by `test/corpus_test.exs`, which is `async: false` — safe).

Every one of the 66 is `async: false` (or `use ExUnit.Case` with no option, which defaults
to `async: false`). Zero direct `Store.clear` callers are async.

## Actual mechanism (the hypothesized one, one hop removed)

`test/amqp/management_rpc_test.exs` — home of the witnessed `Smalt.Amqp.ManagementRpcTest`
W3SessionOps describe — is `async: true` and wipes the SHARED tables in three setup blocks:

```elixir
for table <- [:smalt_sb_queues, :smalt_sb_messages, :smalt_sb_locks] do
  if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
end
```

ExUnit runs tests WITHIN an async module concurrently, so these wipes race sibling tests'
enqueues/dequeues on `:smalt_sb_messages` — DLQ rows vanish mid-flight. This is a
clear-equivalent (`:ets.delete_all_objects` on shared tables) inside an async module, which
the `Store.clear`-grep inventory structurally cannot see. `SmaltTest.Lifecycle.ensure_store_up/0`
does not wipe; it only waits for materialization.

Clear-equivalent sweep (second grep, `delete_all_objects` across test/): 23 additional files
call it — ALL `async: false` except management_rpc_test.exs. management_rpc was the only
async store-wiper in the tree. (test/amqp/fuzz_test.exs and graphlaw tests are async:true but
touch no shared ETS store.)

StoreChurn (`test/store_churn_test.exs`) is `async: false`, uses `:smalt_resources` +
`/churn-test/` prefix only; its run3 list_prefix-empty witness is consistent with the same
era but its table is not wiped by management_rpc — marked UNRESOLVED-but-nonrecurring (see
Falsifiers).

## Fix (one line + comment)

`test/amqp/management_rpc_test.exs` line 2: `async: true` → `async: false`, with comment
citing this receipt chain. Diff: 1 file, +7/-1. Nested `TestLockManager` defmodule left as-is.

## Verification (real output, MIX_BUILD_ROOT=_build-ft-clr)

Full `mix test` runs, 2655 tests each (1 doctest, 7 properties, 61 excluded):

| run | tree | failures | faces |
|---|---|---|---|
| pre-fix witness | HEAD, pre-fix | 2-4/run | management_rpc batch-delete; store_churn list_prefix (postfix receipt) |
| baseline | HEAD file restored for one run | 2 | Amqp.FuzzTest atom-mint; StoreDetsTest mirror-capture |
| C | fix | **0** | — |
| D | fix | 1 | fence-10 timing (314ms > 250ms bound), solo green |
| E | fix | 1 | fence-10 again (timing face) |
| F | fix | **0** | `1 doctest, 7 properties, 2655 tests, 0 failures (61 excluded)`, exit 0 |

Solo check: `mix test test/affidavit_wasm_failclosed_test.exs:511` → `1 test, 0 failures (11 excluded)`.

- The witnessed clear-race class (W3SessionOps DLQ vanish, management_rpc batch-delete) did
  NOT recur in any of the 4 post-fix full runs (C/D/E/F), nor store_churn list_prefix.
- The failure face ROTATED to `fence 10` (affidavit_wasm_failclosed_test.exs:511), a
  wall-clock bound (250ms) under scheduler jitter with its own documented persistent-flake
  history — a DIFFERENT flake class, not the clear-race. It fails only under full-suite load,
  is green solo, and is NOT attributed to this fix (baseline run did not show it, but the
  baseline's own face set was different again; per-run faces do not repeat, consistent with
  load-order sensitivity across the suite, not a regression from serialization).
- No 2-consecutive-green was achieved: C=0, D=1, E=1, F=0. The blocker is fence-10's timing
  bound, not the clear-race.

## Falsifiers / open

1. fence-10: bound-vs-jitter flake, open, pre-existing class (comment in the test itself
   documents the prior 100ms→250ms retune for exactly this). Candidate close: widen bound or
   load-isolate the hammer.
2. store_churn `:smalt_resources` wipe path: no caller found in this audit; if it recurs,
   next suspect is a DETSMirror restore swapping tables mid-walk, not a test-side wipe.

## Attribution note

Baseline (HEAD) run is a single sample; failure faces across all runs are disjoint and
non-repeating, so no face is attributable to the fix with the evidence available. The
clear-race class specifically has not recurred post-fix (4 full runs).
