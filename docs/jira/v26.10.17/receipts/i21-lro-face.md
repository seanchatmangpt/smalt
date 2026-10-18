# i21 — SmaltLroTest :543 op-record store miss (contention face → bounded sweeper-sync retry)

Standing: PARTIAL_ALIVE (face repaired and verified solo + paired; court-x2 not run in this lane)
Context: pair (solo x3 + paired with test/egress_dispatch_test.exs)

## Face (from r241)

`SmaltLroTest "op records reach terminal at rest with zero polls; default retention keeps all 500"` (test/lro_test.exs:543)
failed post-court with `op-record store miss (:error vs Succeeded)` — solo-green 4/4, contention-class.
r241 names the shared mechanism: a cross-module Store teardown/clear racing the test's
fixed `Process.sleep(delay + 10)` → single `sweep_now()` → hard assert.

## Change (lease: timing/fixable parts of test/lro_test.exs only)

- Replaced the fixed sleep + single sweep + hard assert with `sweep_until_terminal/3`:
  a bounded retry-until-or-timeout (deadline 5000 ms) that loops raw store reads of all
  500 ids against the sweeper's observable effect (`Sweeper.sweep_now()` per pass) and
  flunks with a TYPED message naming the offending record keys (missing vs unterminal)
  and the rid. No product code touched.
- No sweeper-sleep synchronization added elsewhere; the eviction face inside the test is
  unchanged (explicit sweeps, deterministic).

## Verification (real output, MIX_BUILD_ROOT=_build-ft-lro2)

Solo 3x after fix:

```
Finished in 0.9 seconds (0.00s async, 0.9s sync)
33 tests, 0 failures            # x3 (run1/run2/run3)
```

Note: pre-fix solo was 1.1–1.4 s; post-fix 0.9 s (retry loop is no slower than the old
fixed sleeps; it exits on first fully-terminal pass).

First fix iteration caught my own defect by the typed message: I had inverted the
`Enum.split_with/2` result order (matching is FIRST), which made the loop always run to
deadline and — via the typed key listing — revealed the inversion. Fixed; the typed
failure surface is doing its job (a wrong-loop would have shown missing=[] forever).

Paired run (after the egress lane's in-flight compile error cleared):

```
Finished in 2.9 seconds (0.00s async, 2.9s sync)
140 tests, 0 failures           # test/lro_test.exs + test/egress_dispatch_test.exs
```

## Shared-tree incidents this session (disclosed)

1. `deps/ex4pm` + `deps/ash_ex4pm` vanished mid-session (another lane's operation) → ran
   `mix deps.get`. This resolved ex4pm 26.10.1 → 26.10.8, consistent with the IN-FLIGHT
   mix.exs (another lane pins `{:ex4pm, "~> 26.10.8", override: true}`). `mix.lock` now
   carries ex4pm 26.10.8 + ash_ex4pm — a diff vs HEAD that matches the in-flight manifest,
   NOT lock drift caused by this lane. Coordinator rules on the lock at integration.
2. test/egress_dispatch_test.exs was briefly non-compiling (rescue-syntax, then undefined
   `prev_cors`/`prev_skr_legacy`) — owned lane fixed both under the compile-freeze SLA; the
   paired run ran only after it compiled clean. No unblock edits by this lane.

## Falsifier (for the next court)

The face is closed only if a full court / paired run reproduces zero
`op-record store miss` failures across the window; if a wipe persists >5 s the new typed
message will name the surviving keys instead of a bare match error.
