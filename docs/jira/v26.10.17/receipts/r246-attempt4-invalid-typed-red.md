# r246 — court-x2 attempt 4: INVALID (mid-gate tree edit) + typed RED; WO-2 carries to v26.10.18

Standing: TYPED-RED (honest; attempt void as two-green evidence)
Date: 2026-10-17 22:40
Log: tmp/court-x2-v17-wrap4.log, COURT_X2_RC=1; run 1 = 5 failures, run 2 =
different-set failures → SHIFTING-FAILURE alarm fired.

## Why attempt 4 is invalid regardless of outcome

The coordinator landed `test/amqp/management_rpc_test.exs` (async: true →
false, receipts/i21d-store-clear-async.md) BETWEEN the two legs: leg 1 and
leg 2 executed different trees, violating the gate's fresh-subject premise.
The two-green claim would be unsound even if both legs had passed. The edit
itself is a real fix (the clear-race class was absent in 4/4 post-fix
full-suite runs) and is committed; the next attempt runs it in both legs.

## Faces witnessed (rotating cluster, new since the repair wave)

- run 1: FuzzTest atom-mint (:561), ShaclFuzz admission/corpus rows, tags
  normalization, error-corpus rows
- run 2: ArmErrorCorpusTest LRO 202/poll, ShaclFuzz 3 rows, TagsNormalization
- Classification: rotating load faces in the async corpus/fuzz suites; the
  repaired r241 set (fence-10 hammer 12/12, ETS 5/5, corpus-soak 3/3,
  QueueStore, budgets) did NOT recur.

## Warm-up leg 0 (same tree, pre-gate)

2655 tests, **0 failures** (406.7s) — the window's first zero-failure
full-suite pass, under tmp/quiet-waiver-attempt4.txt's typed foreign-beam
waiver. The tree is one flake-class wave away from a two-green; the async
store-wipe root cause is FIXED; the remaining rotating faces are
corpus/fuzz-suite load jitter — NEXT_WINDOW WO-A.

## Disposition

WO-2 carries to v26.10.18 typed-RED with the full chain:
r240 → r241 → r246 (attempt 4 invalid + typed RED). 36 gate invocations,
0 two-green. The 10-minute finish loop stops at local midnight per its
charter; the repair (commit this fix, then attempt 5 on a frozen tree) is
v26.10.18's opening move with every precondition already green.
