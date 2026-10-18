# i21c — bench fresh receipt (court bench-check pre-run #1)

Standing: PASS (gate), with one honest first-run failure noted below.

Lane: bench-runner, 80/20 court-stage pre-run #1. Repo /Users/sac/smalt.
No edits, no git. Deliverable: fresh `tmp/bench-receipt.json` + green `just bench-check`.

## Before

`just bench-check` at 20:47 PDT 2026-10-17 (receipt dated 2026-10-16T16:21:07-0700):

```
[COURT] Performance regression gate...
  FAIL detail [receipt]: stale receipt — rerun scripts/bench.py
== Bench Gate ==
  receipt                       28.51 h  (<= 24.0) -> FAIL
Gate: FAIL (0/1 CTQs pass)
exit 1
```

Confirmed the ADV-7 finding: gate fails closed on receipts older than 24h.

## Run: `just bench` (python3 scripts/bench.py)

Machine spec (`just bench-machine`):

```
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

First invocation FAILED: `[FAULT] substrate exited rc=1 before binding :9443`;
`tmp/bench-substrate.log` shows a mix deps convergence error
(ex4pm "~> 26.10.8" in mix.exs vs ex4pm "26.10.1" required by the
`deps/ash_ex4pm` checkout; lock says ash_ex4pm 26.10.4). Did not reproduce on
rerun — second invocation of `python3 scripts/bench.py` (same command, no tree
or lock change by this lane) completed and passed. Classified as transient deps
resolution failure, not a gate defect. Reported honestly per lane law.

Second run (exit 0), 2026-10-17T20:53:51-0700:

```
[BENCH] doctor (substrate stopped, as doctor requires)
  0.737s (target <= 3.0s) -> PASS
[BENCH] substrate boot (spawn -> TCP accept on 9443), 5 runs
  boot run 1/5: 2.660s
  boot run 2/5: 2.574s
  boot run 3/5: 3.621s
  boot run 4/5: 1.943s
  boot run 5/5: 2.227s
[BENCH] ARM PUT round-trip, 200 PUTs
[BENCH] Cosmos doc POST+GET round-trips, 200x
[BENCH] AMQP first-frame latency (connect + 8-byte header), 50 rounds

== Results ==
  doctor        : 0.737s (<= 3.0s) -> PASS
  boot median   : 2.574s  p95 3.621s (<= 5.0s) -> PASS
  arm_put       : p50 0.542ms  p95 0.82ms  p99 1.002ms (p95 < 50.0ms) -> PASS
  cosmos        : p50 0.39ms  p95 0.602ms  p99 0.713ms (p95 < 20.0ms) -> PASS
  amqp_first_frame: p50 0.996ms  p95 1.186ms  p99 5.875ms (p95 < 100.0ms) -> PASS
[BENCH] receipt written: /Users/sac/smalt/tmp/bench-receipt.json
[BENCH] GATE: PASS (5/5 CTQs)
```

## After: `just bench-check`

```
[COURT] Performance regression gate...
== Bench Gate ==
  doctor runtime                0.737 s  (<= 3.0) -> PASS
  boot p95                      3.621 s  (<= 5.0) -> PASS
  ARM PUT p95                    0.82 ms (<  50.0) -> PASS
  Cosmos round-trip p95         0.602 ms (<  20.0) -> PASS
  AMQP first-frame p95          1.186 ms (<  100.0) -> PASS
Gate: PASS (5/5 CTQs pass)
exit 0
```

`tmp/bench-receipt.json` mtime Oct 17 20:53, `date` field
`2026-10-17T20:53:51-0700` — fresh within the 24h window.

## Falsifier check

Re-running `just bench-check` on the pre-run receipt failed (28.51h age); the
same command on the fresh receipt passes with exit 0. The flip is the
non-vacuity witness: the gate discriminates receipt age, and `just bench` is
the remediation, as the justfile states.

## Residue

None removed. First-run failure log at `/Users/sac/smalt/tmp/bench-substrate.log`
(overwritten by the passing run's boot output). Scratch stdout at
`/tmp/b1-bench-stdout.log`. No files under the repo modified except this receipt.
