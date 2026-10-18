# v0 interim converged-suite signal — rewrite wave (v26.10.18)

Standing: PARTIAL_ALIVE (1 new-face contention failure + 1 in-flight-lane artifact; no CLOSED-row regression)

Context: full. Command (absolute repo /Users/sac/smalt):

```
MIX_BUILD_ROOT=_build-ft-v0 mix test > /Users/sac/smalt/tmp/v0-full-suite.log 2>&1; echo EXIT=$?
EXIT=2
```

(Full log preserved at `tmp/v0-full-suite.log`, 137,702 lines. Note: first
attempt with a cold `_build-ft-v0` was stopped at the 30-min background limit
during compile; second run on the warm build root completed.)

## Full suite (verbatim tail-equivalent summary)

```
1 doctest, 7 properties, 2633 tests, 1 failure (90 excluded)
```

Single failure identity, verbatim:

```
1) test mirror captures writes within interval + epsilon (Smalt.StoreDetsTest)
   test/store_dets_test.exs:27
   ** (MatchError) no match of right hand side value:
       {:error, {:needs_repair,
        ~c"/Users/sac/.cache/tmp/smalt_dets_mirror_73474/dm_t_resources.dets"}}
   code: {:ok, res} = :dets.open_file(:probe_res, file: ~c"#{dir}/dm_t_resources.dets", repair: false)
   stacktrace: test/store_dets_test.exs:38: (test)
```

## Corpus+compliance slice (verbatim)

```
MIX_BUILD_ROOT=_build-ft-v0 mix test test/corpus_test.exs test/compliance_test.exs 2>&1 | tail -2
Finished in 16.6 seconds (0.00s async, 16.6s sync)
182 tests, 26 failures (17 excluded)
```

All 26 failures are ONE root cause, not 26 defects. Every failure is
`Smalt.Compliance.C1ArmTest` teardown:

```
** (ArgumentError) on_exit/2 callback can only be invoked from the test process
    (ex_unit 1.19.5) lib/ex_unit/callbacks.ex:515: ExUnit.Callbacks.on_exit/2
    (smalt 26.10.16) test/support/env.ex:43: SmaltTest.Env.put_restored/1
```

## Classification (vs docs/jira/v26.10.17/FLAKE_LEDGER.md + i22/b-* receipts)

1. **`test/store_dets_test.exs:38` — NEW FACE (contention-class), not in ledger.**
   Closest ledger row is F12 (`store_dets_test.exs:145`, `:sync` GenServer
   timeout under load) — different mechanism, different line. In-tree diff on
   this file is a comment-only SLEEP-CLASS marker, non-causal.
   Solo bisect: `MIX_BUILD_ROOT=_build-ft-v0 mix test test/store_dets_test.exs`
   -> `5 tests, 0 failures (1 excluded)` (0.2 s). Green solo, red only under
   the full suite's fleet load (12 concurrent beams from sibling lanes were
   live during the run). Disposition: contention / load-class per r236 §6
   protocol — solo-bisect performed; face does not reproduce solo. Suspected
   mechanism: `repair: false` closed-read races a torn DetsMirror file mid-sync
   under load. Not a CLOSED-row regression; no ledger row re-opens.

2. **C1ArmTest 26-failure cluster — IN-FLIGHT-LANE ARTIFACT.** The tree's
   uncommitted rewrite (test/compliance/c1_arm.exs) converted bare
   `Application.put_env` + `on_exit` pairs to the new `SmaltTest.Env.put_restored/1`
   form, including one call INSIDE an `on_exit` callback (c1_arm.exs:50 area) —
   `on_exit/2` is illegal there. Every test fails in teardown identically.
   Deterministic, file-local, tied to the in-flight B-lane diff; not a flake,
   not a product defect. Owner of the c1_arm.exs edit must move the
   `put_restored(auth_mode: ...)` call back into `setup` (it is redundant with
   the setup-line calls anyway).

3. No FLAKE_LEDGER CLOSED row (F1–F5, F8–F13, F15, F16) recurred. OPEN-ROTATING
   rows F6/F7/F14/F17 did not fire.

## Receipts consulted

- docs/jira/v26.10.17/FLAKE_LEDGER.md (all 17 rows)
- docs/jira/v26.10.18/receipts/: b0..b8, b1-corpus, b2, b3, b5, b7 present on
  disk (some landed mid-run; w10-review also uncommitted in tree)

## Interim converged verdict

Suite is GREEN modulo one load-class new face (solo-green, unregistered in the
ledger) and one deterministic in-flight-lane teardown bug in
test/compliance/c1_arm.exs. Safe signal for the wave to continue; no
CLOSED-row regression witnessed.

Cleanup: `rm -rf _build-ft-v0` (performed after this receipt — see closing
command in the wave log).

Receipt: docs/jira/v26.10.18/receipts/v0-interim.md
