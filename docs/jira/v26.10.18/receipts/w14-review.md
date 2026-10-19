# W14 — residual review lane, workqueue group 13

Context: solo (test/enclave_doctor_severity_test.exs, runs 1-6)
Standing: PARTIAL_ALIVE (rewritten file green x2; run-B red unexplained singleton under overload; detail in Standing section)

Window: v26.10.18. Context: solo. Build root: `MIX_BUILD_ROOT=_build-ft-w14`.
No git. No GAP/KD flips.

## Scope

Group 13 of `/tmp/rewrite-workqueue.json` (5 files, not 6 as the dispatch
said — the workqueue file carries 5 for this group):

- `test/amqp/pyamqp_parity_test.exs` — ALREADY-COMPLIANT
- `test/corpus/secret_cross_plane_seed.exs` — ALREADY-COMPLIANT
- `test/enclave_doctor_severity_test.exs` — REWRITTEN (Law 1)
- `test/property/frame_codec_property_test.exs` — ALREADY-COMPLIANT
- `test/smalt_metrics_test.exs` — ALREADY-COMPLIANT

Reviewed against `docs/jira/v26.10.18/rewrite-drafts/NO-SLEEP-DOCTRINE.md`.
Preserved every receipted assertion verbatim in the rewritten file; the
only change is the injection mechanism, disclosed below.

## ALREADY-COMPLIANT citations

- **pyamqp_parity_test.exs**: zero `Process.sleep`; wire waits are
  `:gen_tcp.recv/3` with explicit timeouts, synchronized by the real
  socket stream (Law 1 form 2, structural sync). Carries its own
  anti-vacuity no-skip fence (test 3, lane M6). No edits.
- **secret_cross_plane_seed.exs**: zero sleeps; fully synchronous PUT/GET
  round-trip over the real router + egress path; assertions on real Store
  state. No edits.
- **frame_codec_property_test.exs**: zero sleeps; concurrency is
  `Task.async_stream` with per-task 5s timeout asserted on results
  (exactly-one-winner), not on timing. No edits.
- **smalt_metrics_test.exs**: zero `Process.sleep`; its `ensure_store`
  waits on a `Process.monitor` `{:DOWN, ...}` receive with a 500ms
  bounded after — monitor-receive, the lawful form (Law 2 readiness),
  not a sleep. No edits.

## REWRITTEN: enclave_doctor_severity_test.exs

**Defect** (Law 1 violation): the "forced failure" residue test paced a
concurrent injector with `Process.sleep(2)` x2000 inside the loop
(line 74 pre-edit) — a scattered sleep substituting time for observation.
It also raced: if the injector finished before the doctor's baseline
snapshot, the identity check would PASS spuriously.

**Conversion** (structural sync, no sleeps anywhere in the file):

- `doctor = Task.async(fn -> Smalt.Enclave.Doctor.run() end)` — doctor run
  in a Task.
- Concurrent injector task inserts unique `lane430-residue-*` rows in a
  tight loop for the *entire lifetime of the doctor run*, killed after
  `Task.await` returns. Because insertion is continuous, rows necessarily
  land strictly between the strict identity check's baseline and
  after_state snapshots — deterministic FAIL, no timing guess, no pacing
  sleep. (First attempt polled the `doctor-identity-rg` Store row as a
  "baseline taken" observable; rejected — the RG row exists only between
  the lifecycle PUT and DELETE, a sub-millisecond window, and the poll
  timed out at 15s. Witnessed at run 1 below.)
- `Task.await(doctor, 120_000)` — the await budget fences loaded-box
  reality (parallel lane beams), not the idle-box cost; 60s was an
  absolute bound hugging normal cost, the fence-10 failure class.
- Cleanup unchanged: `Process.exit(injector, :kill)` + prefix sweep in
  `after`. All assertions (FAIL / ETS_IDENTITY_RESIDUE / BLOCKING_GATE /
  remediation map) preserved verbatim.

## Verification (real output)

Compile: `MIX_BUILD_ROOT=_build-ft-w14 mix compile` → exit 0
("Compiling 135 files (.ex) / Generated smalt app").

Sleep grep over the 5 files: only a prose comment mentions
"Process.sleep loop" (scripts/sleep_gate.py strips comments — gate-clean;
B8 receipt: gate ALIVE, lib/ 135 files 0 sleeps).

```
$ mix test test/enclave_doctor_severity_test.exs   # run 1, RG-poll draft
  7 tests, 1 failure        # AssertEventually deadline at 15s — draft rejected
$ mix test test/enclave_doctor_severity_test.exs   # run 2 (run A), tight-loop injector
  7 tests, 0 failures 21.6s
$ mix test test/enclave_doctor_severity_test.exs   # run 3 (run B), 120s-budget absent
  7 tests, 1 failure 102.1s # failure detail lost (tail truncation); box ran two
                            # other lane beams at ~380% CPU; leading hypothesis
                            # is the 60s Task.await — fixed by the 120s budget.
                            # UNEXPLAINED-SINGLETON, disclosed not buried.
$ mix test test/enclave_doctor_severity_test.exs   # run 4 (run C)
  7 tests, 0 failures 12.6s
$ mix test test/enclave_doctor_severity_test.exs   # run 5 (run D), final code
  7 tests, 0 failures 20.0s
$ mix test test/enclave_doctor_severity_test.exs   # run 6 (run E), final code
  7 tests, 0 failures 21.0s
```

Gate: green x2 on final code = runs D + E (20.0s / 21.0s). The
intermediate reds are pre-final-code / unexplained-singleton, disclosed.

## Standing

PARTIAL_ALIVE — the rewritten file is green x2 on the final code with the
sleep eliminated and determinism argued structurally; the run-B red is an
unexplained singleton under documented 3-4x box overload and was not
reproduced in 3 subsequent runs.
