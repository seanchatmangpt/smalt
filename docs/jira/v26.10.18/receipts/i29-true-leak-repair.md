# i29 true-leak repair — scoped isolation court 6→0

Date: 2026-10-19. Context: pair(i29 true-leak repair lane, isolation-court
scanner twin). Build root `_build-ft-i29`, no git operations.

## Question

The scoped receipt (`i29-isolation-scoped.md`) counted 6 true self-leak
modules. Do the repairs drive the court-classified counted figure to 0 on
both runs of the identical 11-file serial scoped suite, 121/0 maintained?

## Root cause (measured, not assumed)

All six blocks were **scanner cast-lag artifacts, not restore violations**.
ExUnit delivers formatter events as casts and shuffles case order per run
(Runner `shuffle/2`, seed default random); the twin's baseline snapshot at
`case_started` was processed AFTER the case's first setup had already
mutated env — every amqp block carried the module's OWN key inside its OWN
baseline, and cross-module deltas (maa at R129, two port pin-sets inside one
block) moved between runs with the shuffle. Per-test `on_exit` restores were
verified synchronous-before-`case_finished` (decompiled `ExUnit.Runner`:
`spawn_test/3` runs `exec_on_exit` before `run_test` emits `test_finished`;
probe: stamp delay 1 ms, delete visible to the next case).

En-route real violations found and fixed:

- `test/amqp/sas_verifier_test.exs` (2 sites): bare
  `put_restored(k: Application.get_env(k))` re-puts literal `nil` when the
  key is absent — the twin reads `{k, nil}` as a live entry. Converted both
  to the prev-sentinel inline form (unset → `delete_env` restore).
- `test/canonical_projection_test.exs`: comment said "snapshot ALL six
  keys" but code snapshotted only `[:mcp_port]`; now snapshots all six and
  — critically — the on_exit **restores the env BEFORE the app reboot**
  (previous order booted on Lifecycle shifted ports then stomped the env,
  an env/listener mismatch my first fix introduced and measured: 4
  DrScenarios connect-class failures; reverted to env-first ordering:
  stop → restore config-time ports → start → ensure_store_up).

## Scanner repairs (disclosed: test/support is this lane's tree)

`test/support/isolation_formatter.ex`:

1. `sync/0` barrier: formatter publishes its pid via `:persistent_term` at
   `init/1` (the GenServer is anonymous, `Process.whereis` silently no-ops —
   first implementation of this barrier was measured vacuous exactly this
   way and was repaired); env-mutating setup helpers block until the
   formatter has processed `case_started` (baseline precedes mutation).
2. Bounded settle-stability poll (2 ms poll step, 5 s deadline, settles
   early on two consecutive equal snapshots) before every baseline/settle
   snapshot. No `Process.sleep` (receive-after poll step, no-sleep law:
   bounded poll on a real observable, deadline-capped).

`test/support/env.ex`: `put_restored/with` call `IsolationFormatter.sync()`
before capturing prev (no-op when the twin is not running).

`test/canonical_projection_test.exs` `setup_all`: explicit `sync()` before
the raw `Application.put_env` port pins.

## Result — gate MET

Identical command to the scoped receipt (default seed, `--max-cases 1`,
private build root `_build-ft-i29`), two runs after repair:

```
ISOLATION-TWIN SUMMARY modules_leaked=2 tests=121 failures=0   (run 1, exit 0)
ISOLATION-TWIN SUMMARY modules_leaked=2 tests=121 failures=0   (run 2, exit 0)
```

Court classifier (`isolation_court.classify_leaks` with the live 14-pattern
exemption list) over both logs:

```
EXEMPT(...) Smalt.Amqp.R129SessionGateTest   # names only: Smalt.Amqp.* / :inet_gethost_native*
EXEMPT(...) SmaltServicesTest                # names only: Smalt.Security.LedgerWriter
counted=0   (run 1)
counted=0   (run 2)
```

Counted figure: **6 → 0, both runs**; 121/0 maintained; mix exit 0.
Baseline check: the identical suite on the HEAD versions of the four touched
files gives modules_leaked=5 with env-delta blocks (sas_endpoint/sb_shared_key
mid-flight values in their own baselines) — the pre-repair cast-lag figure.
Logs: /tmp/i29_final3.log, /tmp/i29_final4.log, /tmp/i29_headbase.log.

## Full-tree court (disclosed FAIL, out-of-scope classes)

`python3 scripts/isolation_court.py --runtime-only` (MIX_BUILD_ROOT=_build-ft-i29):

```
runtime twin: 19 module(s) leaked; mix exit=2
ISOLATION-TWIN SUMMARY modules_leaked=43 tests=2862 failures=105
runtime verdict=FAIL
```

19 of 43 raw blocks court-counted after the live exemption list. The six
repaired modules hold at full-tree scale — Smalt.Amqp.R129SessionGateTest and
Smalt.CanonicalProjectionTest appear as EXEMPT (names-only, no env delta);
none of the six emits an env-delta block. The 19 counted are other suites'
classes this lane did not touch: `:ocel_dir` (AuthEnforce, EnclaveOcel,
WireTierRefusalSweep/Lifecycle), Lifecycle shifted-port env deltas
(MetadataEndpoints, EventGrid*, AuditedCapabilities, PyamqpParity, AmqpWire,
StoreRead.Lens4, PortCollision, ArmWire, EgressDispatch), `:lro_retention_ms 0`
(EnclaveDoctorSeverity — a doctor-lib scope that already self-restores, worth
its own look), and DETS-mirror name shifts. The 105 failures carry the
concurrent-load pollution disclosed in the scoped receipt (its figure was 101
on the same class of background). Log: /tmp/i29_full_court.log; raw twin
output: tmp/isolation-court-runtime.out.

## Standing

ALIVE for the scoped gate: counted true-leak figure 0 on both runs, 121/0,
court classifier applied from the live exemption list. PARTIAL_ALIVE for the
full tree: verdict FAIL with 19 counted blocks in out-of-scope suites — the
scoped repair claim does not extend to them.
