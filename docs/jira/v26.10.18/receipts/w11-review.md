# W11 residual review — group 10 (review lane, Context: solo)

Window: v26.10.18. Contract: WORKQUEUE.md group 10 of
`/tmp/rewrite-workqueue.json` (6 files). Doctrine:
`docs/jira/v26.10.18/rewrite-drafts/NO-SLEEP-DOCTRINE.md` (Law 1 sub-laws:
bounded polls on observables, structural sync, ratio fences; canonical
helpers `SmaltTest.Env`, `SmaltTest.Store.resilient_*`,
`SmaltTest.Singleton`, `SmaltTest.AssertEventually`). Standing: PASS.
Note: none of this group's files is `lro_notifier.ex` or
`lib/.../router.ex` (other lanes' leases) — no cross-lane exclusions hit.

## Verdicts

| file | verdict | detail |
|---|---|---|
| test/amqp/lock_manager_test.exs | ALREADY-COMPLIANT | zero `Process.sleep`/`:timer.sleep` (grep clean). `async: false` (:2) = structural sync over the shared `:smalt_sb_locks`/`:smalt_sb_sessions` ETS tables. Races are deterministic: injected `now_ms` on every acquire/renew (F3 court comment, :235-238 explicitly notes "no sleeps"); the 200-racer and 50-phase release-vs-claim courts use `Task.async_stream`/`Task.async` + `Task.await`, i.e. event-based coordination, never clock expiry. Receipted pins preserved verbatim: .NET-GUID byte-reorder involution (:287-324), V261014-04 F2/F3, R178j. |
| test/corpus/cosmos_arm_container.exs | ALREADY-COMPLIANT | zero sleeps; `async: false` (:20); setup uses the canonical `Smalt.Corpus.Helper.ensure_store/0` (the post-i22 CANONICAL resilient-clear implementation). INCIDENT→FIX→FENCE header block and both pk-law assertions preserved verbatim (untouched). |
| test/egress_secrets_test.exs | ALREADY-COMPLIANT | zero sleeps; `async: false`; setup = `SmaltTest.Lifecycle.ensure_store_up()` + `Store.clear/0` (structural sync, no settle sleep); all refusals are typed synchronous HTTP assertions (401 challenge, 410/404/400/501 codes). KD-15 mode-blind 401 pin (:133) preserved verbatim. |
| test/ocel_revops_test.exs | ALREADY-COMPLIANT | zero sleeps; `async: true` is safe — the module touches NO shared state: per-run nanosecond tmp dir (@tmp_dir), no env writes, no shared-ETS wipes; all reads go through real `Ash.read!/0` on per-run paths. Receipted fitness pins preserved verbatim (canonical-net selection law :86-99, exact 0.58333... replay math :103-107). |
| test/ocel_test.exs | REPAIRED | only defect in the group: hand-rolled `Application.put_env(:smalt, :ocel_dir, ...)` + unconditional `Application.delete_env` in `on_exit` (:16-19) → replaced with canonical `SmaltTest.Env.put_restored(ocel_dir: @tmp_dir)`. The unconditional delete was the leak-batch1 class (delete_env on a pre-existing value destroys sibling-visible config); Env restores prev-value semantics (put when set, delete when unset). File-cleanup `on_exit` (rm_rf tmp dir) kept. Assertions unchanged. |
| test/smalt_egress_router_test.exs | ALREADY-COMPLIANT | zero sleeps; `use ExUnit.Case` (defaults async: false); setup = ensure_store_up + `Store.clear/0`; ETag 412/SKR/conditional-header assertions are all synchronous real-router calls. Receipted pins preserved verbatim: lane-11 dead-scaffold note (:143-146), SKR challenge-guard pattern (:61-66). |

## Run evidence (MIX_BUILD_ROOT=_build-ft-w11, seed-random, both exit 0)

Touched file, green ×2:

```
$ MIX_BUILD_ROOT=_build-ft-w11 mix test test/ocel_test.exs   # run 1
......
Finished in 0.2 seconds (0.00s async, 0.2s sync)
24 tests, 0 failures
$ MIX_BUILD_ROOT=_build-ft-w11 mix test test/ocel_test.exs   # run 2
....
Finished in 0.2 seconds (0.00s async, 0.2s sync)
24 tests, 0 failures
```

Remaining five reviewed files (x2 where run standalone):

```
$ MIX_BUILD_ROOT=_build-ft-w11 mix test test/amqp/lock_manager_test.exs \
    test/egress_secrets_test.exs test/ocel_revops_test.exs \
    test/smalt_egress_router_test.exs test/ocel_test.exs
Finished in 0.9 seconds (0.5s async, 0.4s sync)
61 tests, 0 failures        # both invocations, exit 0
```

Corpus row runs through its driver (corpus rows are Code.require_file'd by
`test/corpus_test.exs`; a bare `mix test test/corpus/cosmos_arm_container.exs`
cannot compile standalone — helper.exs is not a mix test glob, pre-existing
harness property, not a defect):

```
$ MIX_BUILD_ROOT=_build-ft-w11 mix test test/corpus_test.exs   # x2, both exit 0
Finished in 2.9 seconds (0.00s async, 2.9s sync)
25 tests, 0 failures (1 excluded)
Finished in 2.6 seconds (0.00s async, 2.6s sync)
25 tests, 0 failures (1 excluded)
```

Net: 1 file REPAIRED (ocel_test.exs, env-restore canonicalization, assertions
verbatim), 5 ALREADY-COMPLIANT with citations. 0 sleeps introduced or found.
No git actions.
