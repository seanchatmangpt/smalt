# i29 — w3 session-ops pytest residual face resolved (3 failed → green ×2, zero diff)

Context: pair(i29-verify-residual)
Standing: **ALIVE** — all 3 residual pytest failures re-witnessed green twice, solo,
against a self-booted enforce substrate; no code change required on either side.

## Verdict: stale premise, closed by the Elixir-side fix (F13)

The 3 failures (`test_session_state_round_trip`,
`test_list_sessions_witness`, `test_batch_delete_removes_exactly_n` in
`smalt-cli/tests/test_w3_session_ops.py`) listed in
`i29-verify-residual.md` were **not** a CLI divergence. They were the same
emulator-side store-wipe race the campaign already fixed: the W3SessionOps /
session-state / DLQ tables (`:smalt_sb_queues` / `:smalt_resources`) are
SHARED tables, and the census-time run raced sibling tests' setup wipes.
Root cause receipted on the Elixir side at
`docs/jira/v26.10.18/receipts/i21d-store-clear-async.md` (F13:
`test/amqp/management_rpc_test.exs` `async: true → false`; the file's
comment block names the W3SessionOps DLQ wipe as a witnessed victim).
Verified on disk this session:

```
$ grep -n async /Users/sac/smalt/test/amqp/management_rpc_test.exs
2:  # async: false — setup blocks wipe the SHARED tables (:smalt_sb_queues/
4:  # async:true this raced sibling tests' enqueues (witnessed: W3SessionOps DLQ
6:  # receipts/i21d-store-substrate-async.md — async:false serializes against ALL
```

The CLI tests' premises are CURRENT (they assert exactly the receipted
emulator behavior: session-state round-trip via
`com.microsoft:set/get-session-state`, `get-message-sessions` with explicit
`queue` field, batch-delete nil-body 200 + full drain). No CLI code change,
no test edit — a diff here would have been overclaiming.

## Execution — solo, self-booted, ×2

No canonical-port contention: the w3 lane rides the private 38672/38654
block and the conftest fixture boots its own enforce substrate under
`/tmp/smalt-substrate-cli5.lock` (colima holds 9443/8443/5672 — not on
this lane's path; not evicted).

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/test_w3_session_ops.py -q -p no:cacheprovider
...s                                                                    [100%]
3 passed, 1 skipped in 44.19s
```

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/test_w3_session_ops.py -q -p no:cacheprovider   # run 2
...s                                                                    [100%]
3 passed, 1 skipped in 23.88s
```

The 1 skip is `test_batch_delete_partial_list` — the pre-existing typed loud
skip `SKIP-KD77-RESIDUAL` (stale locked-survivor premise, documented
in-file at `smalt-cli/tests/test_w3_session_ops.py:253-261`), unchanged and
not in scope.

## Lane hygiene

Lane wrote only this receipt. No CLI diff, no test diff, no bench jsonl, no
shared-infra edits. The conftest substrate booted by the session exits with
the pytest process; nothing left listening on 38672/38654 after teardown.
