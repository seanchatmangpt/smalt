# i21b — leak-court closure: compliance corpus c3/c5/c7

- **Date**: 2026-10-17
- **Lane**: i21b leak-corpus (lease: test/compliance/c5_servicebus.exs, c7_events.exs, c3_cosmos.exs)
- **Repo**: /Users/sac/smalt (canonical checkout, no worktrees)
- **Build root**: `MIX_BUILD_ROOT=_build-ft-leak6`
- **Standing**: ALIVE (all leased findings cleared; corpus 157/0 re-verified after dep churn)
- **Court**: `gates/test_isolation_leak_gate.py` + `mix test test/compliance_test.exs`

## Lease delta

| File | Flagged mutations | Fix |
|---|---|---|
| test/compliance/c5_servicebus.exs (4: `:arm_port`, `:egress_port`, `:amqp_port`, `:event_hubs_port`) | setup put_env with no save | save-prev as single-line `prev_x = Application.get_env(...)` locals in setup, Process-dict carry (`{__MODULE__, :ports_prev}`), conditional put/delete restore in the existing supervisor-stop `on_exit` before `Lifecycle.restore_app()` |
| test/compliance/c7_events.exs (3: `:arm_port`, `:egress_port`, `:amqp_port`) | setup put_env with no save | same pattern, `{__MODULE__, :ports_prev}`; c7's partition-freshness fence ([eh] fresh-partition test) untouched; zero assertion changes |
| test/compliance/c3_cosmos.exs (2: `:cosmos_ru_limit`, `:cosmos_master_key`) | test-body put_env, `after` deletes literal | save-prev locals + Process-dict carry, conditional put/delete in the tests' existing `after` blocks; `:auth_mode` handling unchanged |

Leased findings: 9 at start (gate reported 4/3/2 across the three files; lease
estimated ~4/3/3) → 0 after.

## Gate delta (real output)

```
Before: 9 leased findings
  c3_cosmos:751 cosmos_ru_limit; c3_cosmos:794 cosmos_master_key
  c5_servicebus:299-302 arm/egress/amqp/event_hubs port
  c7_events:22-24 arm/egress/amqp port
After: python3 gates/test_isolation_leak_gate.py | grep -cE "compliance/c[357]_"  ->  0
Gate receipt tmp/invariant-gates/test-isolation-leak-receipt.json:
  offender_count=37, tree_verdict=LEAKS (was 49 at i21-leak-batch2 baseline;
  my 9 leased findings plus 3 landed by concurrent lanes in the same window)
Gate exit stays 1 (tree still has out-of-lease offenders — expected, honest nonzero).
```

## Gate-shape finding (save detection)

The gate's save rule only credits a SAVE when `Application.get_env` appears on
a line carrying an assignment (`prev = ...`); an inline get_env inside a
multi-line `Process.put({...}, {Application.get_env(...), ...})` tuple is NOT
a save. First-cut edits cleared c5/c7 only after converting the multi-line
tuple to single-line `prev_x = get_env` locals. Canonical save-prev shape for
future conversions: assign locals first, then `Process.put` the tuple.

## Cross-lane disclosure (deps churn, no source edits)

- mix.exs/mix.lock were mid-flight during this lane (ex4pm 26.10.8 hex-pin
  bump vs deps/ash_ex4pm `== 26.10.1`): mix test was tree-broken (resolution
  error, pre-existing, not session-introduced by this lane). I patch-unblocked
  the regenerable `deps/ash_ex4pm/mix.exs` twice (SLA unblock, deps/ is
  gitignored/regenerable); the sibling lane then landed the durable fix
  (root pin `~> 26.10.1`, lock at 26.10.1, deps re-extracted). I reverted my
  deps/ patch to the pristine hex extraction (backup:
  /tmp/ash_ex4pm_mix.exs.bak) and cleaned the stale 26.10.8 copies from MY
  build root only (`_build-ft-leak6/test/lib/{ex4pm,ash_ex4pm}`). Zero edits
  to mix.exs, mix.lock, or any non-leased file. `just lane-clean` need not
  treat _build-ft-leak6 as orphaned (single file-level clean of two stale dep
  dirs, disclosed here).
- First post-churn run had a window where c5 solo ran 0 tests
  (amqp_wire tag excluded by default) — corrected solo invocation is
  `mix test test/compliance/c5_servicebus.exs --include amqp_wire` (16 tests).

## Verification (real output, post-churn re-run)

```
MIX_BUILD_ROOT=_build-ft-leak6 mix test test/compliance_test.exs
157 tests, 0 failures (16 excluded)          # corpus gate holds (required 157/0)

== c3_cosmos      28 tests, 0 failures
== c7_events      17 tests, 0 failures
== c5_servicebus  16 tests, 0 failures   (--include amqp_wire)
```

## Replay

```
cd /Users/sac/smalt
python3 gates/test_isolation_leak_gate.py | grep -E "compliance/c[357]_"   # empty
MIX_BUILD_ROOT=_build-ft-leak6 mix test test/compliance_test.exs           # 157 tests, 0 failures
for f in c3_cosmos c7_events; do MIX_BUILD_ROOT=_build-ft-leak6 mix test test/compliance/$f.exs; done
MIX_BUILD_ROOT=_build-ft-leak6 mix test test/compliance/c5_servicebus.exs --include amqp_wire
```

No git (per lease).
