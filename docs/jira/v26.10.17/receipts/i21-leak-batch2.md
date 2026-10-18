# i21 — leak-court batch 2 (test-isolation save-prev/restore conversions)

- **Date**: 2026-10-17
- **Lane**: i21 leak-batch2
Context: slice (five leased files + leak-court static scan)
- **Repo**: /Users/sac/smalt (canonical checkout, no worktrees)
- **Build root**: `MIX_BUILD_ROOT=_build-ft-leak2`
- **Standing**: ALIVE (all leased files solo-green; all leased leak-court findings cleared)
- **Court**: `gates/test_isolation_leak_gate.py` (static test-isolation leak court)

## Scope (lease)

| File | Flagged mutation(s) | Fix |
|---|---|---|
| test/affidavit_ingestion_functor_test.exs:26 | `:lro_delay_ms` no save | save prev (`get_env` w/ default) + on_exit conditional put/delete |
| test/enclave_doctor_env_test.exs:10,23 | `:lro_retention_ms` no save | save prev + on_exit/conditional restore in both tests |
| test/arm_error_corpus_test.exs:385/400 | `:arm_rate_limit` literal nil restore | `prev_rate_limit = get_env` outside try; `after` conditional put/delete |
| test/egress_dispatch_test.exs:250/279, 403/440, 2661-2663 | `:skr_allow_legacy_header`, `:egress_cors_origins`, `:arm_port`/`:egress_port`/`:amqp_port` | save prev + `after`-restore via process dictionary (body vars do not leak into `after` — see finding below), isolated-tree ports saved in `boot_isolated_tree` via `Process.put({MODULE,:isolated_ports_prev},...)` and restored in the engine-kill `on_exit` before `SmaltTest.Lifecycle.restore_app()` |
| test/enclave-testbed/enclave_testbed.exs:423 | `:lro_delay_ms` no restore in region | `prev_delay` saved before `try`, restore moved into `after` |

## Finding: try-body variables do not leak into `after`

First conversion used plain `prev = get_env(...)` body locals read from the
`after` block — compile fails with `undefined variable "prev_cors"` (4+4
errors). Elixir `try`/ExUnit `after` clauses are separate scopes; the original
literal restores were shaped that way for this reason. Batch-2 conversions
carry the saved value across the seam via the process dictionary
(`Process.put(:prev_x, prev)` in body, `Process.get(:prev_x)` in `after`).

## Cross-lane disclosure (compile-freeze SLA)

- test/egress_dispatch_test.exs `resilient_clear/1` (setup/helper region owned
  by another lane): the file did not compile mid-session with clause
  `ArgumentError in [message: "..."] ->` — not legal Elixir rescue syntax
  (the `in` form matches aliases only). Minimal unblock fix applied under the
  SLA: narrowed to `ArgumentError ->` with intent-preserving retry loop,
  disclosed in this receipt per the dual-disclosure rule. This fix was
  load-bearing for every leased verification run of this file.

## Verification (real output)

Compile + solo runs (MIX_BUILD_ROOT=_build-ft-leak2, all exit 0):

```
== test/affidavit_ingestion_functor_test.exs
4 tests, 0 failures
== test/enclave_doctor_env_test.exs
2 tests, 0 failures
== test/arm_error_corpus_test.exs
19 tests, 0 failures
== test/egress_dispatch_test.exs
107 tests, 0 failures
```

Court delta (`just leak-court-count` + gate output):

```
Baseline (session start): 9 leased findings across 5 leased files
  affidavit:26, enclave_doctor_env:10, arm_error_corpus:385,
  egress_dispatch:250/403/2661/2662/2663, enclave-testbed:423
After batch: 0 leased findings. Gate grep for leased files is empty.
Total uncovered mutation lines now: 74 detail lines / 49 offender files
(gate receipt tmp/invariant-gates/test-isolation-leak-receipt.json:
offender_count=49, tree_verdict=LEAKS — expected; gate not yet in `just court`)
```

## Residual (out-of-lease, disclosed not fixed)

- test/enclave-testbed/enclave_testbed.exs:20 — `Application.put_env(:smalt, k, v)`
  non-literal key in the ENCLAVE_PRIVATE_PORTS boot block. The gate hard-REFUSEs
  any non-literal key ("unresolved", not coverable by save/restore); outside this
  lease (:423 was the leased line) and predates the batch. Filed here for the
  owner of the enclave-testbed boot script.

## Replay

```
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-ft-leak2 just leak-court-count
python3 gates/test_isolation_leak_gate.py | grep -E "affidavit|enclave|arm_error|egress_dispatch"   # empty for leased set
for f in test/affidavit_ingestion_functor_test.exs test/enclave_doctor_env_test.exs \
         test/arm_error_corpus_test.exs test/egress_dispatch_test.exs; do
  MIX_BUILD_ROOT=_build-ft-leak2 mix test "$f"
done
```

No git (per lease).
