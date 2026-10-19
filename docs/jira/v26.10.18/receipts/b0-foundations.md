# Receipt: B0 FOUNDATIONS — test/support compile path + canonical helpers

Context: pair(test/mix_auth_scope_test.exs, test/lro_test.exs)
Standing: ALIVE (five SmaltTest modules compile + exercised; both reference suites green; detail in Standing section)

Window: v26.10.18. Lane: B0 (solo). Date: 2026-10-18. Repo: /Users/sac/smalt.
Spec: docs/jira/v26.10.18/rewrite-drafts/foundations.md (§1, §2, §3.2-3.4)
+ rewrite-drafts/assert-eventually.ex.md (canonical module of record).

## Scope landed (exactly the 6 items; no test-file migration)

1. `mix.exs` — `elixirc_paths: elixirc_paths(Mix.env())` +
   `defp elixirc_paths(:test), do: ["lib", "test/support"]` /
   `defp elixirc_paths(_), do: ["lib"]`. Standard Mix contract; test/support
   is now a compile path (pre-existing `test/support/tp_oracle/` holds only
   .py/.js — zero .ex, so it contributes nothing to compilation).
2. `test/support/assert_eventually.ex` — `SmaltTest.AssertEventually`,
   verbatim from rewrite-drafts/assert-eventually.ex.md lines 28-129
   (module of record, carries its 2026-10-18 elixirc smoke receipt).
3. `test/support/env.ex` — `SmaltTest.Env.with/2` + `put_restored/1`.
   The two implementer corrections the draft names inline are applied
   (stray `e` removed from the `with/2` restore clause; missing `fn`
   restored in `put_restored/1`). Restore law: `put_env` when prev was
   non-nil, `delete_env` when prev was unset (`:__unset__` sentinel).
4. `test/support/store_resilient.ex` — `SmaltTest.Store.resilient_clear/1`
   (post_seed runs INSIDE the retry window) + `resilient_setup/1` +
   `quiescent_read/2`, all built on `AssertEventually.eventually/2`
   (`retry_on: {ArgumentError, dead-table message}`).
5. `test/support/singleton.ex` — `SmaltTest.Singleton.start_supervised_singleton!/2`;
   unique `{:via, Registry, {SmaltTest.Registry, {module, ref}}}` name,
   `make_ref()` per call; lifetime ownership stays with
   `ExUnit.Callbacks.start_supervised!/1` (imported in-module — the wrapper
   must be called from the test process). Registries are NOT started here:
   started ONCE per run in test_helper (per-test registry starts are
   themselves a collision class).
6. `test/test_helper.exs` — `:stress` added to the default exclude list
   (zero-impact introduction; no test carries the tag yet; re-enable with
   `mix test --include stress`); `SmaltTest.Registry` started once per run
   (guarded nothing — one run, one start). `SMALT_MAX_CASES` block kept
   verbatim. `SmaltTest.Lifecycle` left inline in test_helper UNCHANGED —
   the move to test/support/lifecycle.ex is NOT in this WO's item list, so
   it was not done (the draft's §1 mention is future scope).
   `test/support/case.ex` — `SmaltTest.Case` template (importing
   AssertEventually/Env/Store/Singleton), the lawful carrier for helper
   imports into test modules.

## Verification (real output)

Reference suites (MIX_BUILD_ROOT=_build-ft-b0):

```
$ MIX_BUILD_ROOT=_build-ft-b0 mix test test/mix_auth_scope_test.exs test/lro_test.exs
....
Finished in 1.0 seconds (0.00s async, 1.0s sync)
37 tests, 0 failures
```

New modules compile + function smoke (throwaway
tmp/b0_smoke_test.exs, run through the real test_helper, then deleted):

```
..
Finished in 0.03 seconds (0.00s async, 0.03s sync)
2 tests, 0 failures
```

Covered in the smoke: `eventually` success return;
`put_restored/1` + on_exit restore of BOTH branches (a pre-existing value
restored to :old, a previously-unset key deleted back to nil — asserted in
a second test that runs after on_exit fired);
`start_supervised_singleton!` returns `{pid, via_name}` with
`GenServer.whereis(name) == pid` for a real `{Smalt.ArmGateway.LRO.Sweeper,
tick_ms: :manual}` child; `resilient_clear/0` returns :ok against the real
shared Store.

Defect found+fixed during smoke: `resilient_clear` initially returned the
eventually value `:cleared`, violating its own `@spec :ok` (the draft's
`resilient_setup` does `:ok = resilient_clear(opts)`); implementation now
returns :ok explicitly.

## Concurrent-lane disclosure (compile-freeze SLA)

Two files owned by sibling lanes appeared in test/support/ mid-flight:
`budget_formatter.ex` (13:33, budget-gate lane) — hit my compile with a
SyntaxError (markdown fence at line 58) at 13:33; on re-read the file had
already been fixed by its owner — NO edit from this lane. `wire_helpers.ex`
(13:30, wire lane) — CompileError (undefined start_supervised!/1, missing
ExUnit.Callbacks import) at 13:35; on retry (13:37+) it compiled — the
owner fixed it in flight; NO edit from this lane either. Both were pure
wait-it-out resolves; zero cross-lane file edits made by B0.

## Out of scope (per WO)

Test-file migration (later batches), Lifecycle move to test/support, budget
formatter internals, any generated artifact, any git action.

## Standing

ALIVE for the landed surface: all five SmaltTest modules compile under the
test env and are exercised through the real test_helper path; both
reference suites green (37/37). Migration of consumers is receipt-gated
per later-batch WOs.
