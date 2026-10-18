# i21-leak-batch4 — test-isolation leak court, batch 4 (lane lease: top-4 unleased offender files)

Standing: PARTIAL_ALIVE (batch green; tree-wide gate still FAIL-TREE-LEAKS on files outside this lease)

## Lease

Top-4 unleased offender FILES by mutation count from
`python3 gates/test_isolation_leak_gate.py` at lane start (50 files / 110 mutations uncovered):

| file | mutations (before) |
|---|---|
| `test/e2e/s6_checkpoints/checkpoint_chain.exs` | 5 |
| `test/wire_tier_refusal_sweep_test.exs` | 4 |
| `test/wire/amqp_wire_test.exs` | 4 |
| `test/wire/arm_wire_test.exs` | 4 |

17 of 110 uncovered mutations. None on the excluded/already-leased list.

## Fix pattern (tls_test.exs save-prev/on_exit-restore style)

- The three ExUnit files: `prev = %{...}` map of literal per-key
  `Application.get_env(:smalt, k)` lines in `setup`, closed over by the
  existing `on_exit` blocks, which now restore each key
  (`delete_env` when prev was nil, else `put_env`), before
  `SmaltTest.Lifecycle.restore_app()`.
- `checkpoint_chain.exs` (mix-run script, no ExUnit): `prev` bound BEFORE a
  new `try do ... after ... end` wrapper (try-body locals are not visible in
  `after` — batch-2 scoping note applied); the whole scenario body returns
  `{exit_code, receipt}` through the try; `after` restores all 5 alternate
  port keys; `File.write!/IO.puts/System.halt(exit_code)` moved after the
  try. Scenario semantics unchanged: same ports, same CAS chain, same
  receipt contract.

## Before/after

- Batch-4 files: 17 uncovered mutations → **0** (all four files absent from
  the offender table; gate output re-checked after the edits).
- Tree (all lanes included, concurrent batches landing during this lane):
  50 files / 110 mutations → 33 files / 61 mutations at final re-run.

## Real command output

```
$ python3 gates/test_isolation_leak_gate.py   (before, lane start)
-- OFFENDERS (50 files, 110 mutations uncovered) --
verdict=FAIL-TREE-LEAKS tree=LEAKS offenders=50 fixtures_refused=True

$ MIX_BUILD_ROOT=_build-ft-leak4 MIX_ENV=test mix test test/wire_tier_refusal_sweep_test.exs
3 tests, 0 failures        exit=0

$ MIX_BUILD_ROOT=_build-ft-leak4 MIX_ENV=test mix test test/wire/amqp_wire_test.exs
1 test, 0 failures         exit=0   (file's only non-excluded test; @tag :wire leg also runs green under --include wire)

$ MIX_BUILD_ROOT=_build-ft-leak4 MIX_ENV=test mix test test/wire/arm_wire_test.exs
6 tests, 0 failures        exit=0

$ MIX_BUILD_ROOT=_build-ft-leak4 MIX_ENV=test mix run --no-start test/e2e/s6_checkpoints/checkpoint_chain.exs -- /tmp/s6-leak4
RECEIPT:{"cas_successes_total":200,...,"verdict":"EXACTLY_ONCE_OK","zero_double_processing":true}
exit=0

$ python3 gates/test_isolation_leak_gate.py   (after)
-- OFFENDERS (33 files, 61 mutations uncovered) --
verdict=FAIL-TREE-LEAKS tree=LEAKS offenders=33 fixtures_refused=True
```

## Compile-freeze SLA disclosures

- The in-flight hex-only dep migration lane left the tree unresolvable for
  ~15 min (smalt `{:ex4pm, "~> 26.10.8"}` vs hex ash_ex4pm pinning
  `ex4pm == 26.10.1`; later `deps/ex4pm` stale checkout 26.10.8 vs new lock
  26.10.1). The owning lane landed the mix.exs pin fix (`~> 26.10.1`);
  this lane applied the residual mechanical unblock:
  `mix deps.clean ex4pm ash_ex4pm && mix deps.get` (exit 0) — disclosed
  here. No mix.exs/mix.lock edits by this lane.
- Batch-2's cross-lane egress_dispatch resilient_clear/1 fix was respected:
  that function untouched. enclave_testbed non-literal-key file: skipped
  (out of lease, as directed).

## No git commits made, per lease.
