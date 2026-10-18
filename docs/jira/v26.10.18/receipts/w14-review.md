# W14 residual review — group 13 (relaunch; prior instance died without a receipt)

Standing: PASS
Date: 2026-10-18
Context: solo lane (no git operations, per dispatch)

## Scope

Workqueue group 13 from `/tmp/rewrite-workqueue.json` (5 files; the dispatch
text said "6 files", the workqueue is the contract — the group carries 5):

- `test/amqp/pyamqp_parity_test.exs`
- `test/corpus/secret_cross_plane_seed.exs`
- `test/enclave_doctor_severity_test.exs`
- `test/property/frame_codec_property_test.exs`
- `test/smalt_metrics_test.exs`

Reviewed each against `docs/NO_SLEEP_DOCTRINE.md`. Receipted assertions
preserved verbatim everywhere; no assertion text touched.

## Findings

### ALREADY-COMPLIANT (4 files)

1. `test/amqp/pyamqp_parity_test.exs` — zero `Process.sleep`; recv loops
   block on `:gen_tcp.recv/3` with explicit timeouts (blocking syscalls with
   typed failure, not wait-and-hope); `async: false`; store via
   `SmaltTest.Lifecycle.ensure_store_up/0`. Carries its own anti-vacuity
   no-skip fence (M6).
2. `test/corpus/secret_cross_plane_seed.exs` — zero sleeps; pure
   request/response asserts; store via shared corpus `ensure_store()` helper.
3. `test/enclave_doctor_severity_test.exs` — already W14-converted: the
   paced-sleep injector was replaced by the doctor-Task + bounded
   `SmaltTest.AssertEventually.eventually/2` poll on the
   `doctor-identity-rg` Store row (lines 59-83, comment block cites the
   doctrine); residue insert is synchronous after the observable lands.
4. `test/property/frame_codec_property_test.exs` — zero sleeps; concurrency
   via `Task.async_stream` with `timeout:` and deterministic winner-count
   asserts (P5); `async: false` with a stated tree-global rationale.

### REPAIRED (1 file)

`test/smalt_metrics_test.exs` — local `ensure_store/0` used a
`receive ... after 500 -> :ok` fallback: a wait-and-hope that could proceed
against a dead store (the DOWN-then-recurse arm was fine, the timeout arm
fabricated success). Replaced with the canonical
`SmaltTest.Store.resilient_setup(post_seed:)` (test/support/store_resilient.ex),
which runs the subscription seed INSIDE AssertEventually's retry window —
no clock fallback exists. Local `ensure_store/0` deleted. All 9 test
assertions byte-identical.

## Verification (real output)

Sleep gate, all 5 files (`scripts/sleep_gate.py <file> --as=test`):

```
[SLEEP-GATE] PASS — 1 files, 0 unclassified Process.sleep   (x5, all exit 0)
```

`MIX_BUILD_ROOT=_build-ft-w14b mix test test/smalt_metrics_test.exs` x2:

```
=== RUN 1 ===  Finished in 1.7 seconds (0.00s async, 1.7s sync)  9 tests, 0 failures  exit=0
=== RUN 2 ===  Finished in 1.5 seconds (0.00s async, 1.5s sync)  9 tests, 0 failures  exit=0
```

(The four already-compliant files are unchanged on disk; their suite verdicts
stand as previously receipted, no re-run required for an untouched subject.)

## Diff summary

- `test/smalt_metrics_test.exs`: setup -> `SmaltTest.Store.resilient_setup/1`
  with `post_seed`; removed 19-line local `ensure_store/0`; added
  NO-SLEEP-DOCTRINE citation comment. No assertion changes.
