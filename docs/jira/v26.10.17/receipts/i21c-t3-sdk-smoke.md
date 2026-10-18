# i21c — Court T3 `test-sdk-smoke` pre-run #2

Standing: **PARTIAL_ALIVE** — probes all pass (7/7), but the harness has a
teardown deadlock that only a SIGTERM rescues; under the court's own watchdog
this manifests as the witnessed exit 124.

## Context

Solo pre-run of court stage T3 (`just test-sdk-smoke`), 2026-10-17. No
this-window receipt existed; attempt 1 of the court timed out (exit 124,
30-min watchdog). Lanes: no other lanes on the substrate ports at start
(verified 9443/9444/8443/5672/5673 free via `lsof` before the first run).
No source edits, no git actions.

## Commands and output

Environment: `eval "$(scripts/dev_env.sh)"`, `NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem`.

### Run 1 — exit 2 (substrate never up), ~60 s

```
$ timeout -k 30 1800 node test/sdk-smoke/run.mjs
Unchecked dependencies for environment test:
* ex4pm (Hex package) ... does not match the requirement specified
** (Mix) Can't continue due to errors on dependencies
[sdk-smoke] substrate did not open 9443/8443 within 60s. Substrate log: /Users/sac/smalt/test/sdk-smoke/.logs/substrate.log
EXIT=2
```

Transient: `deps/ash_ex4pm` was mid-flight under another lane's
SLA-unblock (its mix.exs now pins `~> 26.10.8` matching the root override);
`MIX_ENV=test mix deps` reports all deps ok afterward. Duration 60.25 s.

### Run 2 — exit 1, 3 of 7 probes fail with MODULE_NOT_FOUND, ~4.5 min wall

Substrate came up fine (4016 ms); every probe requiring a vendored Azure SDK
failed instantly:

```
Error: Cannot find module '/Users/sac/smalt/test/sdk-smoke/node_modules/@azure/service-bus'
✖ test/sdk-smoke/amqp.test.cjs  'test failed'
✖ test/sdk-smoke/blob.test.cjs  'test failed'
✖ test/sdk-smoke/cosmos.test.cjs  'test failed'
ℹ pass 3 (ARM probes)  ℹ fail 3
```

Cause: `SMALT_SDK_ROOT` unset in my env and `test/sdk-full/node_modules`
missing (machine-local, gitignored; removed at some point). The harness
defaults to `test/sdk-full/node_modules` when `SMALT_SDK_ROOT` is unset
(`test/sdk-smoke/run.mjs:267-269`); probes require
`path.join(SDK_ROOT, "@azure/...")`. Fix applied (build artifact only, no
source edit): `cd test/sdk-full && npm ci --no-audit --no-fund` →
`NPM_EXIT=0` (from committed package-lock.json).

### Run 3 — tests 7/7 PASS, then harness hangs: the real defect

```
[sdk-smoke] substrate up on 9443/8443 after 19577ms
[sdk-smoke] enforce substrate up on 9445/8445 after 2513ms
[sdk-smoke] bearer token minted from enforce STS
✔ amqp: sender either round-trips or rejects with a real error (34.6ms)
✔ ARM: oauth2 client_credentials token has JWT shape and aud payload (35.1ms)
✔ ARM: enforce mode refuses a tokenless request with 401 Bearer challenge (2.1ms)
✔ ARM: GET /subscriptions with minted Bearer returns Enabled subscription with tenant (6.2ms)
✔ blob: create container, upload multibyte, download equal, delete 202 (52.1ms)
✔ blob: immutable container rejects overwrite with 409 (5.8ms)
✔ cosmos: database/container create, item round-trip, stale etag 412, delete (28.8ms)
ℹ tests 7  ℹ pass 7  ℹ fail 0  ℹ duration_ms 286.184041
```

Then node (pid 42570) never exits: 8+ minutes past the test summary with the
beam child (pid 42578, `mix run --no-halt`) still its live child (ppid 42570)
and listening on 9443. Observed wall time to my manual SIGTERM: ~9.5 min
after test completion, with zero further output.

### Typed finding (input for attempt 4): teardown deadlock in run.mjs

`test/sdk-smoke/run.mjs:109`:

```js
process.on("exit", () => { killSubstrate("SIGKILL"); killEnforceRef.fn?.(); });
```

The `exit` handler is the ONLY teardown path after the test run
(`run.mjs:285-287` sets `process.exitCode` and returns from main). But the
spawned `beam.smp` child is kept alive with `--no-halt`, and node's child
process handle keeps the event loop referenced — so the `exit` event never
fires. node waits on beam; beam is `--no-halt` and never dies. Deadlock
until `timeout -k 30 1800` fires → court sees exit 124. The SIGINT/SIGTERM
handlers (line 107) work because they call `process.exit(130)`, which forces
the exit path — witnessed: manual `kill -TERM 42570` → beams gone, 9443/8443
free within 5 s.

Minimal fix shape (not applied — no-edits lane): after
`const code = await new Promise(...)` call `process.exit(code)` (or
`child.unref()` at spawn) instead of setting `process.exitCode` and
returning. One line; the SIGINT/SIGTERM path already proves the mechanism.

## Timing summary

| attempt | wall | result |
|---|---|---|
| run 1 | 60.3 s | exit 2 (deps mid-flight, substrate never up) |
| run 2 | ~4.5 min | exit 1 (3x MODULE_NOT_FOUND, missing vendored SDKs) |
| run 3 | 286 ms test time + ~9.5 min hang (SIGTERM rescue) | tests 7/7 pass |

## Machine

`just bench-machine` is bench-lane infra; not sourced by this lane (receipt
task scope is court T3 pre-run, not a bench jsonl). Omitted per lane scope.

## Notes

- Attempt 2 wrapper was stopped at its background time limit after the test
  summary printed, orphaning a beam on 9443; that beam self-exited and the
  subsequent run refused (exit 3, "port 9443 is occupied") before the port
  cleared. Port law respected throughout — nothing evicted.
- Cleanup after run 3: SIGTERM to the hung node → beams gone, 9443/8443
  free. Verified after teardown.
