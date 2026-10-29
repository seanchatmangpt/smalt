# BK-23 — Popcorn latency-fence repair + scratch promotions

**Standing**: PARTIAL_ALIVE (all changes landed and green under load; ratio
fence not yet non-vacuity-proven — no shim court shows it refusing a mutated
measurement; named residual below)
**Context: solo**
**Date**: 2026-10-21

## Item 1 — Popcorn latency-fence flake (BK-9 residual)

Two popcorn_demo latency tests breached absolute p99 fences under
concurrent-lane compile load but passed 6/6 in isolation (BK-9 receipt). Per
the no-sleep doctrine (absolute-ms bounds fence the machine, not the stack),
both re-fenced in place, `popcorn_demo/test/` only:

- `popcorn_demo/test/empirical_flag_latency_test.exs`
- `popcorn_demo/test/empirical_kv_latency_test.exs`

### Change

Absolute fences (`p99 < 5ms` / `p99 < 10ms`) → RATIO fence: min-of-3 rounds of
(wire p99 / paired baseline p99) < 250, plus an absolute backstop (best-round
p99 < 100ms, the report's remote-SDK figure).

Baseline: test-owned raw `:gen_tcp` loopback echo server (per-connection
accept loop, echo process per connection), same n=100 fresh-connection
round-trip shape, measured in the SAME round as the wire measurement (paired
rounds). Sleep-free by construction; rides the same kernel loopback and
scheduler as the measured path (inflates under the same load) but none of the
stack under test (no smalt router/Plug/Store ETS).

Calibration note: an in-process `:ets` baseline was tried first and REJECTED —
it does not inflate under scheduler-stall load (stayed 1-3µs while wire p99
hit 184ms), so the ratio did not normalize. The echo baseline does (witnessed
baseline_p99 148-2446µs under load).

### Calibration evidence (real runs, machine under concurrent-lane load)

ETS-baseline run (rejected):
```
round 1: p99=184541us baseline_p99=1us ratio=184541.0   (flag)
round 3: p99=2090us   baseline_p99=1us ratio=2090.0     (flag, settled round)
```
Echo-baseline calibration runs (provisional fence 5_000):
```
flag round ratios: 50.8 / 1769.1 / 15.7   (best-round 15.7)
KV   round ratios: 241.2 / 88.1  / 681.3  (best-round 88.1)
```
Worst witnessed loaded min-round ratio = 88.1; settled wire p99 ~1.3ms vs echo
~500µs → settled ratio ~2-3. Fence 250 = ~2.8x over worst witnessed loaded
min-round ratio, ~80x over settled.

### Verification (final, green under the flaking load class)

```
$ cd popcorn_demo && MIX_BUILD_ROOT=_build-bk23 mix test \
    test/empirical_flag_latency_test.exs test/empirical_kv_latency_test.exs
flag round 1: p99=241850us baseline_p99=205us ratio=1179.8
flag round 2: p99=85287us  baseline_p99=154us ratio=553.8
flag round 3: p99=2397us   baseline_p99=193us ratio=12.4    <- best round
KV   round 1: p99=2223us   baseline_p99=233us ratio=9.5
KV   round 2: p99=2703us   baseline_p99=402us ratio=6.7
KV   round 3: p99=45400us  baseline_p99=740us ratio=61.4     <- best round
Result: 6 passed
```
6/6 GREEN under the same concurrent-lane load class that flaked the old
absolute fences (wire p99 spiked to 241ms this run — the old 5/10ms fences
flake exactly here).

### Falsifiers / residuals

- Ratio fence NOT non-vacuity-proven: no shim court shows the new fence
  refusing a mutated (inflated) measurement. Named residual.
- The 100ms absolute backstop fires only on the best-ratio round; single-round
  spikes above 100ms on non-best rounds pass — by design (min-of-N).

## Item 2 — Scratch promotions/deletions (BK-1 residual)

### Promotion: `amqp10_bk1_adversary.exs` → landed court

The BK-1 adversary is a real court (5/5 ×3 reruns witnessed in
amqp10-court-closure.md). Promoted via `git mv`:

- `test/integration/amqp10_bk1_adversary.exs` →
  **`test/integration/amqp10_adversary_court_test.exs`**
- module `Amqp10.Bk1Adversary` → `Amqp10.AdversaryCourt`; moduledoc rewritten
  from "Scratch (not a landed court)" to landed-court status, companion to
  `Amqp10.CrashOnlyCourt`. ADV-1..ADV-5 bodies unchanged.

Verification:
```
$ MIX_BUILD_ROOT=_build-bk23 mix compile    (full smalt app) → Generated smalt app, exit 0
$ MIX_BUILD_ROOT=_build-bk23 mix test test/integration/amqp10_adversary_court_test.exs
Result: 5 passed                          (exit 0)
```
Witnessed output in the run log: `[ADV-3] unknown-handle transfer ->
{:child_crash, #PID<...>, {:unknown_link_handle, 9}}` with
`Process Label: {Smalt.Amqp10.Connection, :connection}` — the typed-exit
contracts hold on the promoted court. Promotion note appended to
`docs/jira/v26.10.21/receipts/amqp10-court-closure.md` (residual 3 → RESOLVED).

### Deletion: `test/tmp_ja10_probe_test.exs` (deleted, `git rm`)

Redundant scratch, deleted. Grounds: JA-10's real court EXISTS at
`test/integration/ja10_transparency_court.exs` — a five-leg court (sys:get_state
census, proc-lib label census, crash-court, telemetry leg, observer-effect
under concurrent load) with its own toolchain pin and test assertions. The
probe asserted nothing (two `IO.puts` inspections of the supervision tree, no
assertions beyond startup) and is fully subsumed by the court's leg 1. Not a
court: deleted, not promoted.

## Receipt

- Files changed: the two popcorn latency tests (fences only, plumbing
  untouched), `test/integration/amqp10_adversary_court_test.exs` (renamed +
  module rename), `test/tmp_ja10_probe_test.exs` (deleted),
  `amqp10-court-closure.md` (residual-3 resolution note), this receipt.
- Commands: popcorn latency pair run (6 passed), full `mix compile` (green),
  promoted-court run (5 passed, exit 0) — all `MIX_BUILD_ROOT=_build-bk23`,
  asdf-pinned elixir 1.20.4-otp-29 / erlang 29.1.2.
- Standing: PARTIAL_ALIVE as stated above. This receipt intentionally left
  uncommitted (per dispatch). Note: the rename and the probe deletion were
  subsequently swept into checkpoint commits by concurrent-lane coordinators
  (rename in 8261a43, deletion in 7276670) — this lane performed no
  `git commit` itself.
