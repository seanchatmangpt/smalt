# ERRC-7 (Raise): recon BEAM-level soak — no BEAM-level leak

- **Date**: 2026-10-15
- **Lane**: ERRC lane 7 (Raise)
- **Repo**: `/Users/sac/smalt` @ main (no commit; work-order task)
- **Target defect**: B-10 soak memory evidence was RSS-only — a raw RSS sawtooth
  ("0.989x/1.011x growth, non-monotonic GC") that cannot distinguish cache growth
  from process-heap leak from binary leak.
- **ADOPT**: `recon` 2.5.x (`{:recon, "~> 2.5", only: :test}` in `mix.exs:100`).

## What ran

- `scripts/bench/recon_soak.exs` (new): boots the full `Smalt.Application`
  (Bandit listeners on ephemeral test ports), drives ARM resource-group
  PUT + list GET traffic (~19 req/s, 5 min, 5389 request cycles), and samples
  every cycle:
  - `:recon.proc_count(:memory, 10)` — top-10 process memory
  - `:erlang.memory(:binary)` — process-wide binary heap bytes
  - `:erlang.system_info(:process_count)` / `(:atom_count)`, `:ets.all()`
- Output: `docs/jira/v26.10.14/bench/recon-soak.jsonl` (5389 rows,
  300 s window, columns `t, proc_count, top_proc_mem, binary_leak_delta,
  ets_count, atom_count`).

## Verdicts (FLAT = no leak in that class)

| curve | first | last | min | max | growth | verdict |
|---|---|---|---|---|---|---|
| proc_count | 1475 | 1475 | 1475 | 1475 | +0.00% | **FLAT** |
| top_proc_mem (top-10 sum, bytes) | 12,961,104 | 13,217,200 | 12,618,144 | 13,365,112 | +1.98% | **FLAT** (GC band ±2%, no trend) |
| binary_leak_delta (:erlang.memory(:binary), bytes) | 2,881,592 | 837,520 | 706,048 | 3,071,528 | −70.94% | **FLAT** (decays to steady ~0.78 MB band) |
| ets_count | 98 | 98 | 98 | 98 | +0.0% | **FLAT** |
| atom_count | 37,557 | 37,616 | 37,557 | 37,616 | +0.16% | **FLAT** (59 atoms over 300 s; +56 of those in minutes 3-4, then flat — warmup atoms, no ongoing creation) |

Decile means (10 equal chunks of the window):

```
proc_count         1475 x10                        (constant)
top_proc_mem       12.93M 12.98M 12.98M 12.92M 13.11M 13.11M 13.12M 13.11M 13.12M 13.11M
binary_mem         1.77M  0.80M  0.80M  0.77M  0.76M  0.77M  0.79M  0.76M  0.78M  0.78M  (declines then flat)
atom_count         37560 37560 37560 37560 37560 37560 37614 37615 37615 37615  (tiny warmup, then flat)
```

## Receipt

- **Command**: `MIX_ENV=test mix run scripts/bench/recon_soak.exs`
- **Exit**: 0; `{"lane":"b11","op":"done"}` emitted; 5389 rows on disk.
- **Bound**: 5-minute single-protocol window (ARM PUT/GET only); the 25-min
  mixed-traffic soak remains the RSS evidence; this is the BEAM-level
  complement, not a replacement. atom_count growth is not proven zero-slope
  over long horizons — a 25-min recon pass would tighten that bound.
- **Falsifier (if re-run finds growth)**: any curve with a monotone
  upward trend beyond its GC band over the window = FIND, route to the
  owning lane.
- **Standing**: ALIVE (witnessed execution, rows re-read from disk at
  receipt time).

## Files

- `scripts/bench/recon_soak.exs` (new)
- `mix.exs` (recon test dep, line ~100)
- `docs/jira/v26.10.14/bench/recon-soak.jsonl` (new, 5389 rows)
