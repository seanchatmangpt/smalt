# W5 residual review — group 4 (solo)

Standing: ALIVE
Context: slice(reviewed-file batch, 65 tests 0 failures)
Date: 2026-10-18
Lane: W5 residual review, group 4 of /tmp/rewrite-workqueue.json
Repo: /Users/sac/smalt
Build root: `MIX_BUILD_ROOT=_build-ft-w5` (deleted after run? — no: lane lease; coordinator cleanup)

## Scope reviewed (6 files, review vs NO-SLEEP-DOCTRINE)

| File | Verdict |
|---|---|
| `test/affidavit_wasm_engine_test.exs` | EDITED — stale vs landed supervised-singleton redesign (see below); doctrine-clean otherwise |
| `test/canonical_projection_test.exs` | ALREADY-COMPLIANT — zero sleeps; on_exit composes with hardened test_helper (below) |
| `test/data_plane/r177d_repro_test.exs` | ALREADY-COMPLIANT — spawn storm is structural sync (receive-count over real spawns, no sleeps) |
| `test/fin_ops_calculator_test.exs` | ALREADY-COMPLIANT — pure functions, `async: true`, no timing anywhere |
| `test/security/lens6_crash_class_test.exs` | ALREADY-COMPLIANT — real Store + real signer, typed refusals, no sleeps |
| `test/telemetry_test.exs` | EDITED — per-suite `wait_until/2` collapsed onto `SmaltTest.AssertEventually` (monotonic deadline, typed observable) |

## canonical_projection on_exit vs hardened test_helper — verified composing

The historic racer was canonical_projection's `Application.stop(:smalt)` in
`setup_all` on_exit, followed by other suites' `ensure_store_up/0` hitting a
dead supervision tree. The hardened `restart_store_child/0`
(`test/test_helper.exs:213-229`) now detects `Process.whereis(Smalt.Supervisor) == nil`
and forces a TRUE REBOOT (`Application.stop` + `restore_app`) instead of
`restart_child` into a dead name — the exact witnessed crash
(warm-up 2026-10-18, AmqpWireTest on_exit vs canonical_projection's stop).
canonical_projection's own on_exit additionally restarts the tree itself
(`Application.stop` → `restore_app` → `ensure_store_up`), so it leaves a live
tree for later on_exits. Both directions of the race are closed. NO EDIT.

## Edits

### 1. test/telemetry_test.exs — canonical-helper collapse

The `prune tick` test used a per-suite fixed-tries poll (`wait_until(fun, 50)`,
10ms steps, generic `flunk("condition never became true")`). Collapsed onto the
landed shared primitive `SmaltTest.AssertEventually.eventually/2` (monotonic
deadline, typed immediate-fail naming the observable). The receipted assertions
after the wait (`refute Map.has_key?...`, `assert Map.has_key?...`) are
preserved verbatim; the now-dead `wait_until/2` (its only call site) deleted.

### 2. test/affidavit_wasm_engine_test.exs — stale missing-artifact face

Pre-existing failure, witnessed failing ALONE (`6 tests, 1 failure` before the
edit): the v26.10.18 lib redesign moved the engine under
`Smalt.Affidavit.WasmEngine.Supervisor` (app-tree child, `application.ex:47`),
whose owner start_links the named singleton at boot. The bogus-path
`start_link` therefore hit the whereis passthrough
(`{:error, {:already_started, pid}}`) before the missing-artifact admission
path ever executed — the assertion was unassertable under the new lib shape.

Fix preserves the receipted assertion verbatim; the test now first frees the
name via the Supervisor's typed seam — a NORMAL `GenServer.stop` makes the
owner classify the stop as intentional and idle (no restart,
`wasm_engine_supervisor.ex` moduledoc), then `AssertEventually` waits on the
observable (`whereis == nil`). Only then does the bogus-path `start_link`
exercise the real admission refusal.

## Verification (real output)

Full six-file set, two runs (different seeds = different order):

```
=== RUN 1 ===
.............
Finished in 4.7 seconds (0.1s async, 4.6s sync)
65 tests, 0 failures
=== RUN 2 ===
...........
Finished in 2.6 seconds (0.4s async, 2.2s sync)
65 tests, 0 failures
```

Touched files individually, two runs each:

```
test/affidavit_wasm_engine_test.exs: 6 tests, 0 failures  (x2)
test/telemetry_test.exs:            14 tests, 0 failures (x2)
```

## Coordinator flags (outside test lane, NOT edited by this lane)

1. **Leftover SHIM-COURT sleep in lib/** — `lib/smalt/affidavit/wasm_engine.ex:137-138`
   (`start_once/1`, `:error` branch):

   ```elixir
   # SHIM-COURT: vacuity probe for fence-10 structural conversion (b3)
   Process.sleep(300)
   ```

   This is a court shim left standing in `lib/` — a Law-2 violation by the
   doctrine's own census rules and on the missing-artifact path this suite
   now exercises (+300ms per refusal). The module docblock simultaneously
   claims "no `Process.sleep` anywhere in this module". Owner: W3/lib lane.

2. **fence10-ratio conversion status** — the doctrine names
   `test/affidavit_wasm_failclosed_test.exs:545-558` fence-10 as evidence; that
   file's `stop_engine/0` still carries a fixed `Process.sleep(25)` settle and
   a fixed-tries `wait_until/2` — those are W3's file, listed here for the
   census, not touched.
