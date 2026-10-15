# Stress: Telemetry Overhead A/B

Real-run A/B of `Smalt.Telemetry` instrumentation overhead on the ARM gateway,
plus counter-contention cost under emitter load.

## Subject

- `lib/smalt/telemetry.ex` (`Smalt.Telemetry` + `Smalt.Telemetry.RollingCounters`)
- ARM PUT path: `PUT /subscriptions/:sub/resourcegroups/:rg` via Bandit.

## Method

- Driver: `scripts/stress/telemetry_driver.exs` (runs under `mix run --no-start`;
  self-boots the app on probed-free ephemeral ports so it never collides with a
  live substrate instance holding 9443/5672/8443).
- Runner: `scripts/stress/telemetry_overhead.py`
  (`python3 scripts/stress/telemetry_overhead.py --json-out tmp/telemetry_receipt.json`)
- 5,000 sequential ARM PUTs (`:httpc`, bearer token minted from the gateway's own
  `/oauth2/v2.0/token` endpoint), 250 PUT warmup, timed with
  `System.monotonic_time`.
- Modes, interleaved a/b × 3 reps (medians cancel first-run warmup drift):
  - **a** — prod wiring: `Smalt.Telemetry.attach()` + `RollingCounters` running.
  - **b** — attach disabled: `:telemetry.detach("smalt-telemetry")`.
  - **c** — attach + DUMP under load: 64 parallel emitter lanes hammering
    `Smalt.Telemetry.admit/refuse` (which funnel through the `RollingCounters`
    GenServer) concurrent with the timed PUTs; 20 `Smalt.Telemetry.dump()`
    samples mid-load; plus an ETS micro-court: GenServer-mediated
    `update_counter` vs direct public-ETS `update_counter`, 64 lanes × 20,000
    bumps.
- Receipt: `tmp/telemetry_receipt.json` (refresh with the runner command above).

## Results (receipted run 2026-10-15, darwin/arm64, 5 interleaved a/b reps)

Receipt: `tmp/telemetry_receipt.json`. Three independent full runs reproduced
the PASS: overhead 0.51% (3 reps), 4.54% (3 reps, machine under other lanes'
beam load), 2.31% (5 reps, below). Spread is machine-load-dependent; all runs
< 5%.

| metric | value |
|---|---|
| a (attached) median | 932 ms / 5,000 PUTs (0.186 ms/PUT) |
| b (detached) median | 911 ms / 5,000 PUTs (0.182 ms/PUT) |
| **overhead (a vs b)** | **2.31% — PASS (< 5%)** |
| c (64-lane emit storm) | 1495 ms → **+60.4% vs a** (30–60% across runs) |
| dump() under load | max 1 ms over 20 samples |
| ETS court (64×20k bumps) | GenServer bump 2263 ms vs direct ETS 543 ms (**4.2× slower**; 4–5.4× across runs) |

## Findings

- PASS: instrumentation overhead 0.51% < 5% threshold. Detaching the handler
  buys essentially nothing; per-request cost is dominated by HTTP/Bandit, not
  telemetry.
- FINDING (contention, not steady-state overhead): `RollingCounters.bump/1`
  routes every counter write through a `GenServer.call` to a single
  `__MODULE__` process even though its ETS table is `:public` with
  `write_concurrency: true` — the GenServer is a needless serialization point.
  Measured 5.4× slowdown vs callers writing `:ets.update_counter` directly
  (1932 ms vs 355 ms for 1.28M bumps, 64 lanes), and a +39% PUT-throughput hit
  under a 64-lane emitter storm (each `admit/refuse` does a bump + a
  `:telemetry.execute`).
- Fix shape (not applied — file owned elsewhere): make `bump/1` resolve the
  table handle once into `:persistent_term` in `init/1` and do the
  `:ets.update_counter` inline in the caller; the GenServer then only ticks
  pruning. `dump/per_minute` can stay GenServer-mediated.
- `dump/0` is cheap even under full emit storm (≤1 ms) — the ETS `tab2list`
  scan is not the bottleneck.

## See Also

- `scripts/stress/telemetry_overhead.py` · `scripts/stress/telemetry_driver.exs`
- `lib/smalt/telemetry.ex`
