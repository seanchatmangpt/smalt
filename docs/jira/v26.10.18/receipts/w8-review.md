# W8 residual review — workqueue group 7

Date: 2026-10-18. Context: solo lane. Contract: review 5 files
(`/tmp/rewrite-workqueue.json` group 7) vs NO-SLEEP-DOCTRINE, canonicalize
where defective, PRESERVE receipted assertions verbatim. Foundations landed
(AssertEventually / Env / Store.resilient / PortEnv in `test/support/`).

Standing: **PASS** — 39 test results across the 5 files, 0 failures, two
Context: solo per-file (5 files, x2, per table below)
green passes each (MIX_BUILD_ROOT=_build-ft-w8).

## Findings + actions (per file)

### test/amqp/cbs_router_test.exs — CONVERTED
No sleeps; sync GenServer calls throughout (Law 1 form 2, ALREADY compliant
on time). Defect: setup used raw `Application.put_env` + unconditional
`on_exit delete_env(:sb_shared_key)` — destroys a pre-existing sibling value
(leak-batch1 finding 2 class). Converted to the canonical nil-preserving
`SmaltTest.Env.put_restored(sb_shared_key: @key)`. Zero assertion edits.

### test/chaos/port_collision_test.exs — CONVERTED (sleep removed)
Law 1 VIOLATION: `Process.sleep(100)` between boot retries
(`boot_with_retry/1`, was line 154) — a fixed sleep as coordination. The
failed boot releases nothing that needs time; the retry loop already probes
FRESH ports each pass, so the attempt bound (12) is the deadline. Removed
the sleep; retry is immediate. Also canonicalized the private
`probe_free_port/0` onto `SmaltTest.PortEnv.free_port/0` (D4 collapse).
All fail-closed assertions preserved verbatim (`already_started` full-tree
refusal, eaddrinuse Bandit co-bind refusal, SHIM-COURT unwrap_exit guards,
first-substrate `200 + @default_sub` checks). The 2s `receive ... after`
on the spawn_monitor is a bounded wait on an event — lawful.

### test/data_plane/vault_data_test.exs — CONVERTED
No sleeps. Defect: setup was the bare `ensure_store_up()` + guarded
`:ets.delete_all_objects` wipe — the ensure→wipe window races an async
sibling's shared-tree teardown (F2-F5 class). Converted to
`SmaltTest.Store.resilient_clear(post_seed: ...)` with the tolerant wipe as
the in-window seed. Zero assertion edits.

### test/kv_secrets_children_test.exs — CONVERTED
No sleeps. Defect: setup was the literal bare `ensure_store_up();
Store.clear()` pattern `SmaltTest.Store.resilient_setup/0` exists to
replace (moduledoc names FLAKE_LEDGER F2-F5/F10). Converted. Zero
assertion edits.

### test/semantic_epoch_test.exs — ALREADY-COMPLIANT + cleanup lease
No `Process.sleep` anywhere; all timing claims are absolute perf budgets on
real work (10k-line parse <5s), not sleep-fences — compliant with the
doctrine and out of ratio-fence scope (no leaked-sleep baseline involved).
Cross-lane tmp collision already fenced (system_time + unique_integer in
the dir name). Defect (lane-cleanup law, not sleep law): the `describe`
suite's fixture dir had NO on_exit reclaim — leaked every run. Added
`ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp) end)` in setup. Zero
assertion edits.

## Verification (real output, two passes each)

Pass 1 (first three together):

```
............
Finished in 0.3 seconds (0.00s async, 0.3s sync)
17 tests, 0 failures        # cbs_router 12 + vault_data 2 + kv_secrets_children 3, exit 0
```

Pass 1 (remaining two):

```
1 test, 0 failures          # port_collision, exit 0
21 tests, 0 failures        # semantic_epoch, exit 0
```

Pass 2 (each file, individually):

```
test/amqp/cbs_router_test.exs        => 12 tests, 0 failures  (exit 0)
test/chaos/port_collision_test.exs   => 1 test,  0 failures  (exit 0)
test/data_plane/vault_data_test.exs  => 2 tests, 0 failures  (exit 0)
test/kv_secrets_children_test.exs    => 3 tests, 0 failures  (exit 0)
test/semantic_epoch_test.exs         => 21 tests, 0 failures (exit 0)
```

No git operations performed (per contract).
