# BK-MON3R — BK-MON3-F1 dead accumulator-fallback join repaired (ALIVE)

**Standing:** ALIVE — the "serve live accumulator numbers on store-miss metrics GET" half of the fallback contract is now live end to end, falsifiers refuted on real wire faces, non-vacuity witnessed (pre-fix tree fails the same court).

Context: solo

Lane: BK-MON3R. Owner of the fix: this lane (router.ex handle_metrics region + `lib/smalt/monitor/metrics.ex`). Subject SHA note: HEAD moved mid-lane via coordinator tick checkpoint 51e794a5, which swept this lane's in-flight edits to HEAD as an in-flight snapshot ("owners hold their files"); lane commit carries the receipt only. Post-sweep byte-equality verified: `git show HEAD:<file> | shasum -a 256` equals the working tree for all three files —
- `lib/smalt/arm_gateway/router.ex` `f479fa97…`
- `lib/smalt/monitor/metrics.ex` `95d7bca9…`
- `test/internal/bkmon3r_deadjoin_court_test.exs` `7baa4841…`

## Defect recap (from bkmon3-final-standing.md F1)

Two dead joins, not one — read both sides before picking the fix:

1. `router.ex` handle_metrics fallback: `String.starts_with?(r, downcase(res_id) <> "|")` over `raw_rows/0` keys. `record/4` keys rows `{downcased resource, metric, bucket}` with nothing after the resource, so the `|` continuation never exists → `acc_rows` always 0 → store-miss metrics GET always the real-Azure empty envelope.
2. `lib/smalt/monitor/metrics.ex series/5` had the SAME dead `|` prefix filter (`prefix = downcase(resource_id) <> "|"`). Fixing only the router would have made `acc_rows > 0` and still served a dense zero-fill — a subtler lie. Both filters now use exact downcased-resource equality (the `|` idiom belongs to `Smalt.Metrics`' string-keyed table, not this tuple-keyed ETS).

## Fix

- router.ex (~1596-1612): predicate → `r == String.downcase(res_id) and m == metric`, comment updated (attribution BK-MON3-F1, bkmon3r-deadjoin-fix).
- metrics.ex series/5 (~93-103): `wanted = String.downcase(resource_id)`; row filter → `r == wanted and m == metric`, comment updated.

## Court: test/internal/bkmon3r_deadjoin_court_test.exs (new, 4 legs)

Chicago discipline: real `:telemetry.execute` into the real attached handler, real tuple-keyed ETS, real HTTP/1.1 over loopback against the self-booted ArmGateway.Router. No mocks, no sleeps.

- **L1 (the falsifier):** store-miss GET for X with accumulator rows → 200 carrying nonzero Requests totals AND RequestDuration total ≥ 42.0. Pre-fix this returned `{"value":[]}`.
- **L2:** store-miss GET for unknown Y → 200 empty envelope (unchanged behavior pinned).
- **L3:** case-insensitive — rows recorded under the handler's mixed-case canonical path, route id in different casing → served.
- **L4:** exact-equality does not leak sibling resource rows (`nsl4` vs `nsl4x`).

```
MIX_BUILD_ROOT=_build-bkmon3r scripts/fast_test.sh test/internal/bkmon3r_deadjoin_court_test.exs
  Result: 4 passed   (wall 121s, build root _build-ft-75715b96)
```

## Non-vacuity (shim-court protocol, manual run)

BASELINE (pre-fix HEAD content) → run court → AFTER (fixed) → RESTORE (sha256 byte-exact, verified):

```
git show HEAD:router.ex/metrics.ex → swap in → court: Result: 2/4 passed
  L1 FAILED (empty envelope: assert [%{"timeseries" => ...}] = value)
  L3 FAILED (case-insensitive leg, same empty-envelope face)
→ restore fixed copies; sha256 router/metrics byte-exact (f479fa97… / 95d7bca9…)
```

A court that passes on the pre-fix tree would be vacuous; L1 and L3 both flip, L2/L4 pin unchanged faces and correctly hold on both.

## Regression wings

```
scripts/fast_test.sh test/internal/plane_blast_radius_test.exs      → Result: 6 passed
scripts/fast_test.sh test/internal/armstrong_idiom_court_test.exs
                     test/internal/expl9r2_arm_guard_court_test.exs
                     test/internal/expl10r_court_test.exs           → Result: 31 passed
smalt-cli (MIX_BUILD_ROOT=/Users/sac/smalt/_build-bkmon3r):
  pytest tests/test_ty_monitor.py tests/test_ty_login.py            → 11 passed in 137.33s
```

ty first run with a relative MIX_BUILD_ROOT loud-skipped (8/11, SUBSTRATE_DIED — boot compiled into a path outside the repo); rerun with the absolute lane build root green. Lane lesson: the conftest substrate boot resolves MIX_BUILD_ROOT against REPO_ROOT — pass it absolute.

## Residues (typed, not silently dropped)

- The platform pseudo-resource (`subscriptions/_smalt_monitor/...`, no leading slash) remains unaddressable as a metrics ROUTE (odd post-ns segment count) — the receipt's full close condition named a platform route; this lane's assignment scoped the dead join only. The join itself is repaired; platform rows still aggregate under the pseudo-resource key and `metric_alerts.ex` default-source reads them via `series/5` directly (its `resourceId` default), so the alerting face is intact.
- `plane_blast_radius_test.exs` (heir parity + EgressRefused raw_rows) green post-fix — `series/5` consumers unaffected.

Verification ladder: internal wire court (4 legs) → regression wings (37 Elixir + 11 py). All green on `_build-bkmon3r`.
