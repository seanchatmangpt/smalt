# Receipt: B8 — doctrine/gates (sleep gate + NO-SLEEP-DOCTRINE landing)

Context: pair(test/enclave_doctor_severity_test.exs, test/lro_test.exs)

Date: 2026-10-18 · Lane: B8
**Standing:** **PARTIAL_ALIVE** (gate ALIVE + non-vacuous; test-side honest red = deliverable)

Subject (absolute): /Users/sac/smalt — scripts/sleep_gate.py (new),
scripts/shim_court/sleep_gate_court.sh (new), justfile.d/29-sleep.just (new,
imported in Justfile),
scripts/verify_all.sh (sleep-gate stage), docs/NO_SLEEP_DOCTRINE.md (new),
lib/smalt/enclave/state.ex:163-170 (predicate inversion fix + annotation),
lib/smalt/enclave/doctor.ex (2 annotations), plus 13 `# SLEEP-CLASS: TIME-ADVANCE`
annotations in test/ (B1 class). router.ex / pplan/task.ex / wasm_engine.ex
annotations were made, then obsoleted the same session by the concurrent
lib-redesign lane REMOVING those sleeps entirely (delete outranks annotate);
their sites now pass by absence.

## Command output (embedded, per receipt law)

Gate (lib/ — PASS after lib-redesign lane removed 4 of 6 sleeps):

```
$ python3 scripts/sleep_gate.py lib/
[SLEEP-GATE] PASS — 135 files, 0 unclassified Process.sleep
lib=0
```

Gate (full tree — honest red: 38 unclassified test/ sites are the repair-WO
surface, deliverable per B8 task; count as-of 2026-10-18 ~13:50, may drift
with concurrent lanes):

```
$ python3 scripts/sleep_gate.py
[SLEEP-GATE] 38 violation(s) across 297 files — REFUSED
...
[SLEEP-GATE] lawful forms: bounded poll inside an audited implementation, or # SLEEP-CLASS: TIME-ADVANCE (test) / census class (lib). See docs/NO_SLEEP_DOCTRINE.md
```

Court (non-vacuity):

```
$ bash scripts/shim_court/sleep_gate_court.sh; echo court=$?
[self-check] sha256 restore-detection verified
[SHIM] baseline sha256(.../subject.exs) = a8131e22...
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to .../subject.exs (SHIM-COURT marker present)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] sleep_gate court: clean PASSES, injected sleep REFUSED (both sides), restore byte-exact
court=0
```

Compile + targeted tests (state.ex predicate fix):

```
$ MIX_BUILD_ROOT=_build-b8 mix compile --warnings-as-errors; echo $?
0   (no warnings in the 4 edited lib files)
$ MIX_BUILD_ROOT=_build-b8 mix test test/enclave_doctor_severity_test.exs test/lro_test.exs
40 tests, 0 failures
```

## Notes

- **state.ex:165 inverted predicate FIXED** (latent bug): slept AFTER
  terminal, polled hot on 202 → now `if conn.status == 202, do:
  Process.sleep(@lro_poll_ms)`; targeted suite green (40 tests, 0 failures).
- Concurrent-lane interactions: b3's transient SHIM-COURT probe briefly
  appeared as an unclassified lib sleep (honest red at the time); the
  lib-redesign lane then removed it. Coordinator SLA flag about my session
  breaking test/sdk-smoke/run.mjs was REFUTED on disk: `node --check
  test/sdk-smoke/run.mjs` exit 0; I made no edit to that file.
- verify_all wiring: stage `sleep-gate` added as a LOUD SKIP with live
  violation count (SLEEP_GATE_ENFORCE=1 enforces). Skip, never fake pass.
  Standalone: `just sleep-gate` (exit 1 by design while test/ sites are
  unannotated — honest red), `just sleep-gate-court` (exit 0).
- Fail-closed paths: unreadable file, zero files scanned, out-of-repo path
  without `--as=test|lib` all exit 1.
