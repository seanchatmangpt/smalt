# Receipt: i27 — solo bisect of the v2-soak rotating faces
Context: solo(per-file bisect rows, each file 2x under _build-ft-rot)

Date: 2026-10-18 (~20:55–21:05 PDT) · Tree: working tree, `git rev-parse HEAD` = `014bb7ab0b70df4ef87baeb27ce380e6af468200`
Lane: bench-runner rotating-bisect wave (no edits to lib/test, no git actions).
Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}` (`just bench-machine`)
Build root: `MIX_BUILD_ROOT=_build-ft-rot`.

## Method

Each face's file run SOLO, 2 consecutive runs, sequential, no other traffic on the
checkout. Logs: `/tmp/rot-<file>-{1,2}.log`. Classification law: both runs fail
with content = DETERMINISTIC; passes solo = ROTATING-LOAD (shared-teardown
F2/F8/F10 signature).

Tree disclosure: HEAD moved past the soak tree (`c6f6243`): docs-only commits plus
in-flight `lib/smalt/enclave/state.ex` (+20), `lib/smalt/enclave/doctor.ex`,
`lib/smalt/arm_gateway/lro_sweeper.ex`, `lib/smalt/projection/canonical.ex`,
`lib/smalt/store/dets_mirror.ex` and the `test/azsim/*` batch now on disk. Solo
behavior may differ from the soak tree; per-file verdicts below are on THIS tree.

## Per-file table (solo x2)

| File | Runs failed | Verdict | Solo signature |
|---|---|---|---|
| `test/azsim/topology_test.exs` | 0/2 | **ROTATING-LOAD** | 8 tests, 0 failures, exit 0 both |
| `test/azsim/dets_recovery_test.exs` | 0/2 | **ROTATING-LOAD** | 5 tests, 0 failures, exit 0 both |
| `test/enclave_ocel_test.exs` | 2/2 | **DETERMINISTIC** | `ORPHANED_DATA_PLANE_ROWS_DETECTED` — residue `:smalt_sb_queues: ["resourcewritesuccess"]` after destroy, `Lifecycle.run` returns `{:error, {:stage_failed, :lifecycle, _}}` (`test/enclave_ocel_test.exs:62`) |
| `test/enclave_lifecycle_test.exs` | 2/2 (both tests) | **DETERMINISTIC** | same residue signature (`:63`, `:128`) |
| `test/enclave_state_test.exs` | 2/2 | **DETERMINISTIC** | same residue signature (`:214`) |
| `test/pplan_test.exs` (lens7 :2875) | 2/2 | **DETERMINISTIC** (new solo signature) | `Supervisor.terminate_child(Smalt.Supervisor, Smalt.Store)` → `{:error, :not_found}` (`test/pplan_test.exs:2889`) — `Smalt.Store` is not a live child of `Smalt.Su
pervisor` in the solo boot |
| `test/ash_extension_test.exs` (Lens7FieldPolicy) | 0/2 | **ROTATING-LOAD** | 14 tests, 0 failures, exit 0 both |
| `test/dspy_test.exs` (DSPy esc round-trip) | 0/2 | **ROTATING-LOAD** | 14 tests, 0 failures, exit 0 both |
| `test/lro_test.exs` (LRO at-rest) | 0/2 | **ROTATING-LOAD** | 37 tests, 0 failures, exit 0 all legs |

## Enclave cluster collapse

**YES — one shared cause.** `enclave_ocel_test.exs`, `enclave_lifecycle_test.exs`
and `enclave_state_test.exs` fail identically solo: `Lifecycle.run/2` destroy stage
leaves residue `:smalt_sb_queues: ["resourcewritesuccess"]` and trips
`ORPHANED_DATA_PLANE_ROWS_DETECTED` (`lib/smalt/enclave/lifecycle.ex:163`).
Three files, four failing tests, one mechanism: the enclave destroy path does not
delete the `resourcewritesuccess` Service Bus queue. One ledger row for the
cluster, not three. The soak's TopologyTest face (ARM PUT emits
ResourceWriteSuccess, runs 1–2) is plausibly downstream of the same row's
presence (its assertion is on that event's body), consistent with its
ROTATING-LOAD solo-green verdict.

## Classification summary

- DETERMINISTIC (fix, not probation): enclave cluster (1 mechanism, 3 files),
  PPlan lens7 `terminate_child → {:error, :not_found}` (1 test, new solo
  signature — the soak signature `{:noproc,_}` typed is the load-mode variant
  of the same not-a-live-child window).
- ROTATING-LOAD (ledger-probation class): TopologyTest, DetsRecovery,
  Lens7FieldPolicy, DSPy round-trip, LRO at-rest — all solo-green 2/2.

## Evidence commands

```
MIX_BUILD_ROOT=_build-ft-rot mix test <file>   # per row above, 2x each
# exit 0 = green; ExUnit summaries verbatim in /tmp/rot-<tag>.log
```

## Standing

**PARTIAL_ALIVE** (bisect executed and receipted; the DETERMINISTIC rows are
diagnosed, not fixed — per task scope, capture + report only).

## Cleanup

`_build-ft-rot` remains on disk (lane build root; coordinator reclaim at
integration per cleanup law).
