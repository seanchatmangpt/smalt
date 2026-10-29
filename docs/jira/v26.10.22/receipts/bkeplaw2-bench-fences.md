# BK-EPLAW2 — fail-closed startup fences for bench harness self-boots

**Standing:** ALIVE
Context: solo
Follow-on: BK-EPLAW (docs/jira/v26.10.22/receipts/bkeplaw-ephemeral-ports.md) — that lane
wired `SmaltTestBoot.pin!` into a1/b9 but typed them "same class, doc-only contract". This
lane converts the doc-only contract into a fail-closed fence.

## Census re-run (BK-EPLAW scoring, scripts/bench/*.exs + scripts/stress/*.exs)

`Application.ensure_all_started(:smalt)` callers: a1, b42, b9, benchee_runner, ja9,
telemetry_driver.

- already fenced/pinned (safe): b42 (BK-EPLAW), ja9_scaling (explicit pins),
  telemetry_driver (explicit pins)
- **newly fenced this lane**: `scripts/bench/benchee_runner.exs` — boots `:smalt` in-process
  in run_b7b/run_b8b/run_b9b; bare `mix run` scored MIX_ENV-dev without pins → same class as
  a1/b9 before BK-EPLAW. Was NOT covered by BK-EPLAW's fix (it only wired b42/a1/b9).
- fenced per task: `a1_change_feed.exs`, `b9_eh_beam.exs`

No other bench/stress exs boots `:smalt`.

## Fix

- `scripts/lib/test_boot_ports.exs` — NEW `SmaltTestBoot.fence!/1` + `pin!/0` now records
  `:persistent_term.put({SmaltTestBoot, :pinned}, true)`. `fence!` fails closed:
  - FATAL `{:canonical_port_binding, hits, fix}` if any listener env equals its canonical
    front-door port (checked FIRST, so even a pin! + canonical pin cannot slip through);
  - FATAL `{:missing_pin_contract, ...}` if neither `pin!/0` ran in this VM nor any
    `SMALT_TEST_<NAME>_PORT` env pin is present;
  - otherwise `:ok`.
  Violations print a typed `[FATAL] <harness>: pinned-port contract VIOLATED` block naming
  the fix, then `System.halt(1)` — never boot on canonical defaults.
- `scripts/bench/a1_change_feed.exs`, `scripts/bench/b9_eh_beam.exs` — `fence!("...")` call
  inserted between `pin!` and `ensure_all_started`.
- `scripts/bench/benchee_runner.exs` — helper require + `pin!` + `fence!` at the top-level
  entry, before any lane boots the app.

Production substrate boot untouched.

## Witnesses

### Negative (fence fires, fail-closed, exit 1)

Fence invoked in a fresh VM without `pin!/0` under bare dev config (canonical env present):

```
$ MIX_BUILD_ROOT=_build-eplaw2 mix run --no-start -e '
  Code.require_file("test_boot_ports.exs", Path.join(File.cwd!(), "scripts/lib"))
  SmaltTestBoot.fence!("negative-witness")
  IO.puts("UNREACHABLE — fence did not fire")'
[FATAL] negative-witness: pinned-port contract VIOLATED — refusing to boot on canonical defaults.
Reason: {:canonical_port_binding, [{:arm_port, "ARM", 9443}, {:egress_port, "EGRESS", 8443}], ...}
Fix: Code.require_file("test_boot_ports.exs", Path.join(File.cwd!(), "scripts/lib"))
     SmaltTestBoot.pin!(); SmaltTestBoot.fence!("negative-witness")
     (or export explicit SMALT_TEST_<NAME>_PORT pins off the canonical five)
exit=1
```

### Positive (real harness boot with the fence; lsof during boot)

`BENCH_OUT_DIR=tmp/eplaw2-witness BENCHEE_TIME=1 BENCHEE_WARMUP=0 mix run --no-start
scripts/bench/benchee_runner.exs b9b` (fenced entry), 1s lsof poll over the canonical five
for the whole boot window. Harness log: every listener bound EPHEMERAL
(63409 arm / 63410 tls / 63412 amqp / 63413 eh / 63414 mcp / 63416 wps / 63417 acl /
63418 kafka). The only canonical-port lsof hits during the window are
`beam.smp pid 76567, started 04:44:10` — attributed by `ps` to the REAL flock-managed
substrate beam (`mix run --no-start --no-halt -e ... Application.put_env(:smalt, :arm_port, 9443) ...`),
not the harness. Zero canonical binds attributable to the harness.

Note (pre-existing, not session-introduced): the b9b lane itself then crashed on
`Benchee.run/2 is undefined` — benchee is not loadable under bare `mix run` MIX_ENV
(test-profile dep). The harness never booted canonical; the fence is not on that path.
The b9/benchee MIX_ENV=test documented runs are unaffected.

## Regression

```
$ MIX_BUILD_ROOT=_build-eplaw2 mix test test/internal/eplaw_ephemeral_boot_court_test.exs
Finished in 10.1 seconds (0.00s async, 10.1s sync)
Result: 3 passed
```

Parse check: `Code.string_to_quoted!` OK on all 4 edited exs files.

## Falsifier

A fenced harness that boots and binds any of 9443/9444/8443/5672/5673 — or a fence
invocation without `pin!`/env pins that exits 0 — reopens this ticket.
