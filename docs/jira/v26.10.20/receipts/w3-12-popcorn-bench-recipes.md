# W3-12 — popcorn bench recipes (justfile.d/42-popcorn-bench.just)

**Standing:** **ALIVE** — all three recipes executed for real against the UP
substrate (exit codes witnessed below); the two bench lanes PASS with their
relative fences green.

## Files (lane-owned)

- `justfile.d/42-popcorn-bench.just` (new) — module with prefixed vars
  (`POPCORN_BENCH_ROOT/POPCORN_BENCH_DIR`), shebang recipes with
  `set -euo pipefail`, per same-checkout-fanout law 5.
- `Justfile` — one import line appended (follows the 40/41 convention):
  `import 'justfile.d/42-popcorn-bench.just'`

## Recipes

- `popcorn-bench-legs` — exec `popcorn_demo/scripts/bench_legs.sh`
  (existence checked, typed loud failure if missing).
- `popcorn-bench-cook` — exec `popcorn_demo/scripts/bench_cook.sh`;
  absent file → `[SKIP] … (concurrent lane W2-11)` + exit 0 (loud, typed).
  bench_cook.sh already landed, so the real path was exercised.
- `popcorn-bench-fence-check` — dependency on `popcorn-bench-legs`; the
  script owns the fence, the recipe surfaces its exit fail-closed.

## Parse check (real output)

```
$ just --justfile justfile.d/42-popcorn-bench.just --list && just --list | grep popcorn-bench
    popcorn-bench-cook        # pass, never a silent skip.
    popcorn-bench-fence-check # surfaces its exit code unchanged, fail-closed.
    popcorn-bench-legs        # row-to-row (regression = median_ms > 2x the previous row for the same leg).
MODULE-LIST-OK
    popcorn-bench-cook                                # pass, never a silent skip.
    popcorn-bench-fence-check                         # surfaces its exit code unchanged, fail-closed.
    popcorn-bench-legs                                # row-to-row (regression = median_ms > 2x the previous row for the same leg).
ROOT-LIST-OK
```

## Real runs (substrate UP, pid 28225; ports 9443/9444/5672/5673)

`just popcorn-bench-legs` → **EXIT=0**:

```
substrate: UP
== results (/Users/sac/smalt/popcorn_demo/bench/legs.jsonl)
  PopcornDemo.Live median=520.0ms max=2106.1ms errors=0 fence=ok(fence 942.8ms)
  PopcornDemo.LiveMatrix median=468.3ms max=470.8ms errors=0 fence=ok(fence 1138.2ms)
  PopcornDemo.LiveBlob median=468.2ms max=477.8ms errors=0 fence=ok(fence 962.0ms)
BENCH_LEGS: done ts=2026-10-21T01:14:31Z runs=5
EXIT=0
```

`just popcorn-bench-cook` → **EXIT=0** (cook lane already landed; real run):

```
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); live=OK(endpoints,tenants,sts,subscriptions=1)
boot: 894 ms (exit 0)
…
{"lane": "cook", "phase": "cook", "median_ms": 3280, "runs": 2, "runs_ms": [3993, 2568], "ts": 1792545294, "errors": 0}
{"lane": "cook", "phase": "boot", "median_ms": 892, "runs": 2, "runs_ms": [894, 889], "ts": 1792545294, "errors": 0}
FENCE: PASS (all phases within 1.5x previous recorded median)
EXIT=0
```

`just popcorn-bench-fence-check` → **EXIT=0** (dependency wiring proven):

```
  PopcornDemo.Live median=471.5ms max=633.2ms errors=0 fence=ok(fence 1040.0ms)
  PopcornDemo.LiveMatrix median=493.2ms max=510.2ms errors=0 fence=ok(fence 936.6ms)
  PopcornDemo.LiveBlob median=493.8ms max=624.6ms errors=0 fence=ok(fence 936.4ms)
BENCH_LEGS: done ts=2026-10-21T01:15:00Z runs=5
EXIT=0
```

## Compile-freeze disclosure (SLA, no edit by this lane)

First two runs of `popcorn-bench-legs` failed with `FAIL(no-LEG_OUT)` —
pre-existing concurrent-lane compile breaks in popcorn_demo in-flight files
(`live_mcp.ex:118` syntax, then `live_policy.ex`, then `live_queue.ex:342`,
each edited moments later by its owning lane). This lane applied **zero**
fixes — polled until the owning lane stabilized the tree (~6 min), after
which all legs passed. Result rows appended to
`popcorn_demo/bench/legs.jsonl` + `bench/cook.jsonl` are lane-owned files of
the bench lanes (the recipes write nothing else).

## Falsifier

`just popcorn-bench-legs` exiting 0 with a broken fence, or
`popcorn-bench-cook` exiting 0 silently on a missing script. Neither
observed; both recipes fail-closed by construction.
