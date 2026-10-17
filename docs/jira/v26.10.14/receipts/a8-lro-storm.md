# Receipt: A-8 LRO sweeper storm under high-rate cancellation

- Date: 2026-10-15 21:40-21:47 PDT (run 5, the landed jsonl; earlier runs are
  described under Session findings)
- Lane: A-8 (adversarial cross-product bench wave, v26.10.14)
- Repo: `/Users/sac/smalt`, branch main, darwin/arm64, OTP 28.3.1 /
  Elixir 1.19.5, `MIX_ENV=test mix do run --no-start --no-compile`
  (the `mix do` form avoids the c7 lane's `pkill -f "mix run --no-start"`
  fence, which SIGTERMed three earlier runs — exit 144)
- Script (owned by this lane): `scripts/bench/a8_lro_storm.exs` — mints
  10,000 InProgress LRO records into `:smalt_operations` in the exact
  `Smalt.ArmGateway.LRO.start_op/1` record shape (startedAtMs + delayMs,
  delay spread 1-30s), cancels 5,000 mid-flight via
  `Store.compare_and_swap/4` (CAS-serialized against the sweeper's shared
  `evaluate/2` write, dispatch times sorted and spread uniformly over the
  30s window), with the sweeper live at the 30s tick, `:erlang.memory(:ets)`
  sampled every 500ms.
- Output: `docs/jira/v26.10.14/bench/a8-lro-storm.jsonl`
- No commits, no lib edits.

## Results

| metric | value |
|---|---|
| mint | 10,000 ops in 29 ms (344,828 ops/s) |
| cancel storm | 4,994 wins / 6 misses (99.9%), miss_already_terminal=6 |
| miss anatomy | all 6 misses dispatched in the 25-30s bucket, just past the 29.95s sweeper tick that flipped them first |
| convergence | 60,023 ms from mint t0 until ALL 10,000 terminal |
| ETS memory | 8.4-8.6 MB across 120 samples (flat, no growth) |
| final statuses | Cancelled=4994, Succeeded=5006 |

## Convergence anatomy (why 2 ticks)

Convergence = second sweeper tick, not the first. Sweeper started ~50 ms
before mint t0, so ticks land at ≈t0-50ms, t0+29.95s, t0+59.95s. At the
29.95s tick, ops whose delayMs exceeds 29.95s (the tail of the 1-30s spread)
are not yet due — a few ops straddle the tick boundary and hold
`non_terminal > 0` until the 59.95s tick. Structural bound:
convergence ≈ ceil((max delay − tick phase)/tick + 1) × tick when
window_ms == tick_ms. In real-Azure terms a client polling with Retry-After
would see terminal states far sooner (lazy `get_op/1` evaluation), so this
is an at-rest-convergence bound only.

## Invariants

| invariant | result |
|---|---|
| zero non-terminal records at convergence | PASS (0) |
| zero resurrected records (cancel-win → non-Cancelled final) | PASS (0) |
| cancelled half intact (terminal is whichever landed, never a zombie) | PASS — Cancelled=4994 stable through the 60s tick |
| sweep/poll divergence (same shared evaluate/2) | none — every flip is the identical persisted terminal |
| verdict | PASS |

## Session findings (runs 1-4, pre-landing)

- Runs 1-3 exit 144: killed by the c7 lane's `pkill -f "mix run --no-start"`
  fence (two foreground, one background). Fixed by `mix do run` form.
- Run 4 (win rate 10.0%, convergence 71.9s, miss_already_terminal=4496):
  diagnosed via the win/miss-vs-time histogram — the cancel dispatch schedule
  was unsorted, so each cancel fired at the running prefix-max of scheduled
  times, clustering ~99.6% of dispatches into the 25-35s buckets. Fixed with
  `Enum.sort_by(fn {_id, at} -> at end)` (one line). The 10%-win data was a
  bench artifact, not substrate behavior — a minimal probe (1 op, delay 10s,
  cancel at 1s → CAS :ok, stays Cancelled through the 30s tick) plus a timer
  probe (recursive wait_until fires on schedule to ±1ms) isolated the defect
  to the bench scheduler, not the sweeper.
- A peer lane extended this script mid-session (miss-kind accounting + the
  win/miss-vs-time histogram) after the initial landing attempt; the
  diagnostics are what identified the scheduler defect. No lib files touched
  by this lane.
- Concurrency note: `Store.compare_and_swap/4` (Store GenServer-serialized)
  gives the cancel path exactly-once semantics against the sweeper's
  evaluate/2 write with no lock — 6 observed conflicts/terminal-reads at the
  tick boundary were cleanly classified misses, zero zombies.

## Real-Azure divergence row

| dimension | smalt emulator | real Azure ARM |
|---|---|---|
| write quota | 10k ops minted in 29 ms | ~1.2k writes/hour/subscription → 8.3 hours and 9+ subscription shards for the same storm |
| convergence | 60s (two sweeper ticks) | client Retry-After lazy evaluation dominates; no at-rest sweeper bound observable at this scale |

The emulator's 10k-in-minutes IS the divergence: this storm consumes ~1/12
of a real subscription's hourly write budget per second of wall clock.
