# i29 GracefulStopTest boot-premise fix (F59 face)

Standing: PASS (6/6 green, structural fix, no sleeps)

Context: slice(x6)

## Defect

`test/azsim/graceful_stop_test.exs:73` failed deterministically under load
(F59-family) at the boot premise: `GenServer.whereis(Owner)` ran before the
app tree finished starting, so "WasmEngine owner must be running (app booted)"
flunked before the typed `:killed`-vs-`:shutdown` fence ever executed.
Witnessed: `docs/jira/v26.10.18/receipts/i29-soak-recheck.md`,
`i29-eg-gracefulstop-classify.md`.

## Fix (structural, sleep-free)

Setup lookup replaced with a bounded poll on the real boot observable —
`SmaltTest.AssertEventually.eventually/2` over `GenServer.whereis(Owner)`
(`{:ok, pid}` | `{:retry, last}`), `deadline_ms: 10_000`. On timeout the
flunk is typed: names the observable ("WasmEngine owner running (app booted)")
and the last observed value. No `Process.sleep`; poll helper is the audited
one per `docs/NO_SLEEP_DOCTRINE.md`.

All downstream assertions preserved verbatim — the typed
`assert_receive {:DOWN, ^ref, :process, ^owner, :shutdown}` pinion and the
4.5s elapsed fence are untouched.

## Verification

```
$ for i in 1..6; do MIX_BUILD_ROOT=_build-ft-gs1 mix test test/azsim/graceful_stop_test.exs; done
3 tests, 0 failures   (x6)
```

6/6 green, all three tests (`azb22b` tagged subtree-stop test plus both
Bandit child-spec fences) executing in every run — the typed-termination
assertion now actually runs under load.

## Session-introduced failures

None from this lane's diff. A mid-session compile abort in
`lib/smalt/data_plane/key_vault_actions.ex` (TokenMissingError, missing `end`)
was a foreign lane's in-flight edit (compile-freeze window ~runs 4-6 of the
first batch); it resolved on that lane's own write and all runs after it are
green with this lane's diff unchanged. Disclosed per compile-freeze SLA —
no fix applied by this lane.

## Falsifier

Re-introduce the bare `assert is_pid(GenServer.whereis(Owner))` under a
loaded machine and the F59 face returns; the poll version observes the same
`whereis` state, so a genuinely dead owner still fails (typed, with last
observed value) within 10s.
