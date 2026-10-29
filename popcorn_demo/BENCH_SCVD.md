# BENCH_SCVD — SCVD host-side measurement (S2 lane)

Standing: **ALIVE (host-side leg)** — real runs, 46/46 clean rows, zero errors,
zero breaches (34 original S2 rows + 12 S14-A2 extension rows, N 512–4096).

- Script: `popcorn_demo/scripts/bench_scvd.sh`
- Results: `popcorn_demo/bench/scvd.jsonl` (46 rows, one per {phase, n, run})
- Machine (`just bench-machine`): `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.3","otp":"28","darwin":"26.2"}`
- Toolchain: asdf elixir **1.20.3-otp-28**, `MIX_BUILD_ROOT=_build-s2`
- Subject: `PopcornDemo.Concurrency` (S1) — `ramp/1`, `contention/1`;
  deterministic smalt-layer verification walk (`Smalt.CosmosSql` + `SbRules` +
  `Registry`), all three modules confirmed loaded host-side.

## Protocol

PRD §5 host-side. Baseline (cold VM, N=1, full `:erlang.memory` map), ramp
N ∈ {1,2,4,8,16,32,64,128,256} × 3 runs each (each run a FRESH `mix run` —
cold numbers), contention {32,128} × 3 runs. S14-A2 extension: ramp
N ∈ {512,1024,2048,4096} × 3 runs, same fresh-VM protocol, same `timeout 120`
fence per run (a timeout or VM refusal at a rung would BE the wall, typed). Every row carries in-VM
`ramp_wall_ms` (`:erlang.monotonic_time`), p50/p99 per-actor wall
(microseconds), `verified`/`breaches`, and `:erlang.memory(:processes)` +
`:total` after the phase. Contention rows omit p50/p99 (contention/1 reports
no per-actor walls — omitted, never zero-filled; wall measured in-VM as
`vm_wall_ms`).

## Baseline — single-process resource tax

Cold-VM snapshot (`:erlang.memory`, run 1):

| field | KB |
|---|---|
| total | 66,951 (~65.4 MB) |
| processes | 16,765 |
| code | 14,868 |
| ets | 835 |
| atom | 699 |
| cold ramp(1) wall | 4.78 ms (p50=p99=4,747 µs), verified=1 |

## Ramp (median of 3 cold runs)

| N | med wall ms | walls (r1/r2/r3) | med p99 ms | verified | breaches | med processes KB | med total KB |
|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | 2.41 | 2.3/2.4/2.7 | 2.38 | 1/1/1 | 0 | 15,914 | 65,972 |
| 2 | 3.20 | 3.1/3.2/3.5 | 3.15 | 2/2/2 | 0 | 16,988 | 67,245 |
| 4 | 2.80 | 2.7/2.8/2.8 | 2.73 | 4/4/4 | 0 | 16,990 | 67,241 |
| 8 | 2.80 | 2.7/2.8/2.9 | 2.76 | 8/8/8 | 0 | 16,120 | 66,242 |
| 16 | 2.75 | 2.6/2.7/3.7 | 2.68 | 16/16/16 | 0 | 17,151 | 67,183 |
| 32 | 3.03 | 3.0/3.0/3.1 | 2.94 | 32/32/32 | 0 | 16,996 | 67,028 |
| 64 | 5.08 | 3.4/5.1/5.4 | 4.79 | 64/64/64 | 0 | 17,082 | 67,110 |
| 128 | 5.13 | 4.5/5.1/5.5 | 3.22 | 128/128/128 | 0 | 17,498 | 67,737 |
| 256 | 6.02 | 5.3/6.0/9.8 | 4.93 | 256/256/256 | 0 | 18,003 | 68,146 |
| 512 | 13.88 | 11.1/13.9/25.2 | 6.18 | 512/512/512 | 0 | 18,050 | 69,074 |
| 1024 | 36.11 | 28.1/36.1/38.1 | 10.06 | 1024/1024/1024 | 0 | 18,707 | 69,732 |
| 2048 | 76.52 | 92.1/71.2/76.5 | 17.49 | 2048/2048/2048 | 0 | 19,586 | 71,190 |
| 4096 | 293.60 | 293.6/286.7/297.3 | 31.08 | 4096/4096/4096 | 0 | 24,764 | 79,504 |

Threshold Wall analysis (S2 ≤256 + S14-A2 512–4096): sequential median-wall
ratios vs the 2.00x linear-doubling expectation — 1→2: 1.33x, 2→4: 0.88x,
4→8: 1.00x, 8→16: 0.98x, 16→32: 1.10x, 32→64: 1.68x (jitter-class),
64→128: 1.01x, 128→256: 1.17x, **256→512: 2.31x, 512→1024: 2.60x,
1024→2048: 2.12x, 2048→4096: 3.84x**. Verdict: **the flat regime ends at
N=256 — the scaling wall opens at 512**. Below 512 the wall is flat within
noise (2.4–6.0 ms); from 512 on every doubling ratio exceeds 2.00x and the
curve steepens (2.12x–3.84x), i.e. mildly super-linear growth, not a cliff:
no rung timed out (all 12 runs < the 120s fence, worst 297.3 ms) and the VM
refused nothing — verified=N and breaches=0 at every run through 4096. Typed:
this is a **super-linear scaling wall, not a hard/jail boundary**; where the
hard boundary (timeout/VM refusal) sits is still open at N>4096.

Marginal cost per actor (N=1→256 medians): ~8.2 KB processes memory per
additional actor; wall sub-linear (256 actors in 6.02 ms).

S14-A2 memory trend (medians of 3): processes KB 18,050 (512) → 18,707
(1024) → 19,586 (2048) → 24,764 (4096); total KB 69,074 → 69,732 → 71,190 →
79,504. Honest reading: near-linear ~0.7–0.9 KB/actor through 2048 (same
regime as S2's ~8.2 KB/actor gross-process accounting — a spawned process
holding a walk result costs less resident than its initial heap), then a
**~5.2 MB processes jump at 4096** (~4.6x the 2048→4096 actor delta of
~2.3 MB at the old rate) — scheduler/heavy-actor-class growth, measured not
extrapolated; the per-actor constant does not survive past 2048.

## Contention (CAS, 8 keys, x3)

| N | winners (verified) | committed_rows | vm_wall ms (r1/r2/r3) |
|---:|---:|---:|---|
| 32 | 8/8/8 | 8/8/8 | 0.7/1.2/0.8 |
| 128 | 8/8/8 | 8/8/8 | 1.2/1.1/1.1 |

Exactly one winner per key at both actor counts; `assert_contention_final/2`
deterministic at every run; deterministic-final assertion never fired
`not_deterministic`.

## Tier verdicts (PRD targets: Tier1 <500ms/<16MB, Tier2 <750ms/<24MB, Tier3 <1200ms/<32MB)

Basis: worst observed ramp rung of the S2 tier set (N=256, median-of-3;
S14-A2 rungs 512–4096 sit outside the PRD tier set — see Threshold Wall).
Latency = ramp wall;
memory = ramp-attributable increment over the cold-VM baseline
(total_med − 66,951 KB baseline), because the ~65 MB cold BEAM footprint is
host-runtime overhead (16.7 MB of it processes + 14.9 MB code), not cost of
the ramp itself. Both readings reported — see honesty note.

| tier | target | measured (worst rung) | verdict |
|---|---|---|---|
| Tier 1 | <500 ms / <16 MB | 6.02 ms / +1.2 MB increment | **PASS** (83x / 13x margin) |
| Tier 2 | <750 ms / <24 MB | 6.02 ms / +1.2 MB | **PASS** (124x / 20x margins) |
| Tier 3 | <1200 ms / <32 MB | 6.02 ms / +1.2 MB | **PASS** (199x / 26x margin) |

Honesty notes:

1. **Host-side, not the wasm twin.** These verdicts qualify the HOST BEAM
   (OTP 28, JIT) subject. The in-browser (wasm BEAM) leg is a different
   subject: tier standing there is UNKNOWN until the browser leg runs.
2. **Whole-VM reading.** Against absolute VM footprint (~65 MB cold total),
   the <16/24/32 MB memory budgets would REFUTE at every tier — but that
   footprint is dominated by the host runtime, not the actor fan-out; it is
   the same before and after any ramp. This divergence is typed, not hidden.
3. **Dollar claims: NOT MEASURED — out of scope (typed).** This lane measured
   latency and memory only. The PRD's dollar-displacement claims are
   receipts-not-prose: no dollar figure is asserted, implied, or inherited
   from this receipt. Any dollar claim requires its own measurement protocol.
4. **Threshold Wall** (updated by S14-A2): the flat regime ends at N=256.
   Extension rungs: 256→512 2.31x, 512→1024 2.60x, 1024→2048 2.12x,
   2048→4096 3.84x (medians-of-3) — every post-256 ratio exceeds the 2.00x
   linear expectation, so **the scaling wall is LOCATED at N=512** (first
   rung past flat). It is super-linear growth, not a hard boundary: no
   timeout, no VM refusal, verified=N at 4096 in 293.6 ms median. Hard
   boundary open at N>4096 (untested, not refuted).

## Errors

Zero error rows. Zero `environment_skip` outcomes, zero
`invariance_breach` outcomes across all 39 ramp + 6 contention runs
(includes the 12 S14-A2 extension runs; zero `mix-failed-or-timed-out`).

## Session incident (disclosed)

First full-lane attempt (pre-fix) hung: S1's `ramp/1` used an unguarded
`receive` whose actors died silently mid-S1-edit, blocking the parent
forever — my lane hung with it (killed two stale beams, PIDs 33768/32164,
from other lanes' ramp probes; mine 41009). Typed for the record: ramp's
`receive` is un-bounded, so an actor crash converts to a silent parent hang;
a bounded-receive deadline is the structural fix (S1's side). My lane now
wraps every VM run in `timeout 120` so a hang degrades to a typed
`mix-failed-or-timed-out` error row instead of a stalled lane.

## In-browser memory (S9 lane) — the 32MB ceiling measured where it binds

Standing: **PARTIAL_ALIVE** — real in-browser measurements, but the surface
where the ceiling binds hardest (the BEAM wasm worker heap) is not exposed to
any measurable API; typed below, not papered over.

- Runs: `node scripts/browser_smoke.mjs` ×3 (substrate UP, pid 37113,
  ports 9443/9444/5672/5673 all UP; `live=OK` on every run, exit 1 only from
  the pre-existing `kv=FAIL(wasm-transport eprotonosupport)` leg — prior
  receipts 20261021T012954Z/013518Z show the same in-wasm TCP limitation as
  `kv=SKIP`, so session-neutral).
- Instrumentation: `public/app.js` (S9 block) — after the boot receipt
  settles, reads `performance.memory` (main thread), probes Popcorn globals
  for a `WebAssembly.Memory` handle, and calls
  `performance.measureUserAgentSpecificMemory()` (COOP/COEP present,
  `cross_origin_isolated: true`). Emits exactly one
  `console.log("BROWSER_MEM_ROW ...")` per run and appends
  `— mem js X.XMiB[/page/wasm] of 32MiB budget` to the `#legs-summary` line.
- Machine: Apple M3 Max, 16 cores, 48 GB, macOS 26.2; Chromium headless shell
  156.0.8078.4 (chrome-headless-shell-1248).

### Measured (run 1 of 3; runs 2-3 row dropped — see disclosure 3)

```
BROWSER_MEM_ROW {"lane":"browser-mem","js_used_bytes":10000000,
"js_total_bytes":10000000,"page_bytes":null,"wasm_bytes":null,
"wasm_surface":"unreachable: measureUserAgentSpecificMemory threw:
SecurityError: ... not available","budget_bytes":33554432,
"cross_origin_isolated":true,"ts":"2026-10-21T04:46:29.875Z"}
```

| surface | measured | vs 32MB budget | verdict |
|---|---|---|---|
| main-thread JS heap (`performance.memory`, quantized) | 10,000,000 B used / 10,000,000 B total (~9.5 MiB) | 9.5 / 32 MiB | **PASS** (3.4x margin) |
| whole-page incl. workers (`measureUserAgentSpecificMemory`) | not available (SecurityError despite `crossOriginIsolated=true`; headless shell does not implement the exposure) | — | **UNMEASURABLE-(exposed-surface)** |
| BEAM wasm worker JS heap (`performance.memory` in worker) | `null` in worker context (API absent there) | — | **UNMEASURABLE-(exposed-surface)** |
| `WebAssembly.Memory` size via Popcorn globals | no handle on `window`/`globalThis` (BEAM runs in a dedicated Worker; `Module` not global; probed `Popcorn`/`Module`/`HEAP8`/`instance.exports.memory`) | — | **UNMEASURABLE-(exposed-surface)** |
| beam.wasm static reservation (source-read, not runtime) | `beam.mjs` line 135: `new WebAssembly.Memory({initial:1024, maximum:32768, shared:true})` = 64 MiB initial pages | reservation alone exceeds 32MB | **REFUTED on reservation** — but reservation is virtual address space, not committed heap; committed-heap claim stays UNMEASURABLE |

### Typed overall verdict

- **PASS, quantized-class**: main-thread JS heap ~9.5 MiB vs 32MiB budget.
  Chrome quantizes `performance.memory` under COOP/COEP (exactly 10,000,000 —
  a bucket value, not a precise count).
- **UNMEASURABLE-(exposed-surface)** for the BEAM wasm worker: the ceiling
  binds THERE (BEAM heaps + wasm linear memory), and no exposed API reaches
  it. One supplementary probe evaluated inside the worker via Playwright
  (`page.workers()[0].evaluate`) — `performance.memory` absent, `Module` not
  global. The close condition for flipping this to PASS/REFUTED is a Popcorn
  or harness change that exposes the worker's `WebAssembly.Memory` buffer
  size (e.g. `Module.wasmMemory` on the worker global) or CDP-level
  `Performance.getMetrics` on the worker target.

### Disclosures

1. **`kv=FAIL` is pre-existing**, not session-introduced: same
   `:eprotonosupport` in-wasm TCP limitation appears as `kv=SKIP` in prior
   receipts. `live=OK` (the gate) on all three runs.
2. **`measureUserAgentSpecificMemory` SecurityError** despite
   `cross_origin_isolated:true` — the headless shell build does not expose
   the API; not a page misconfiguration.
3. **Row-delivery race in the smoke harness**: `browser_smoke.mjs` closes the
   browser on the same `live=` poll that fires the rows, so console rows are
   delivered in only some runs (1 of 3 in this wave; both rows together).
   Rows emit reliably from the page (verified with a standalone probe that
   waits 3s post-receipt: rows 2/2). Fix belongs in the harness (drain
   console events before `browser.close()`); `browser_smoke.mjs` is not an
   S9-owned file, so disclosed instead of edited.
4. Numbers are single-run per surface with no warm-up variance control; the
   quantized 10MB bucket was identical across every run observed (4 runs),
   so the PASS margin claim is bucket-stable, not precision-stable.

## In-browser memory — worker `WebAssembly.Memory` measured (W14-E, CDP close)

S9's UNMEASURABLE-(exposed-surface) close condition is met via `Module.wasmMemory`
exposure: the Popcorn wasm worker allocates **67,108,864 bytes (64 MiB)** —
`initial: 1024` pages, the emscripten/Popcorn default — stable from boot through
+60s (12/12 samples byte-identical). **Verdict vs the PRD 32 MB ceiling: REFUTED**
(2.0x budget, allocated-reservation measure). Renderer RSS 328→343 MiB post-settle
corroborates wasm-side allocation; page JS heap ~1.7 MB.
Witness: docs/jira/v26.10.20/receipts/wasm-memory-cdp-witness.md.
Remaining unmeasured: committed-heap breakdown per target (CDP Performance
unsupported on worker targets in this headless shell). Tuning direction (not
measured): `initial` pages are a reservation default, likely lowerable for the
slice workload — a falsifier lane, not a documented constant.

## Tail invariance, 9 runs per rung (W15-C, PRD §2.3)

Standing: **ALIVE** — 63 real runs (7 rungs × 9), zero failures, zero errors,
verified=N / breaches=0 at every run. Rows appended to
`popcorn_demo/bench/scvd.jsonl` (`wave: "w15c-tail9"`, runs 1–9).
Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.3","otp":"28","darwin":"26.2"}`
Toolchain: asdf elixir 1.20.3-otp-28, `MIX_BUILD_ROOT=_build-w15c`,
fresh `mix run` per run, `timeout 120` fence per run (typed
`mix-failed-or-timed-out` on breach; zero fired).

Re-measures the W15-B 3-run rungs (16–4096) at 9 runs: 3 runs make p99 the
worst run (a single outlier flips the verdict; witnessed at N=256 run 3,
9.75 ms vs 2.7–6 ms peers). Two metrics, kept distinct:

- **Actor tail (the §2.3 invariant)**: per-actor p99/p50 within a run,
  median across the 9 runs.
- **Across-run wall**: p99/p50 of the 9 `vm_wall_ms` samples — a whole-VM
  cold-boot jitter metric, not the §2.3 per-actor tail.

| N | actor p50 µs (med) | actor p99 µs (med) | actor ratio | actor verdict | wall p50 ms | wall p99 ms | wall ratio | wall verdict |
|---:|---:|---:|---:|---|---:|---:|---:|---|
| 16 | 3,360 | 3,388 | 1.01 | PASS | 3.40 | 4.15 | 1.22 | FAIL (across-run) |
| 128 | 3,872 | 3,980 | 1.03 | PASS | 5.80 | 7.49 | 1.29 | FAIL (across-run) |
| 256 | 4,320 | 4,504 | 1.04 | PASS | 6.10 | 10.39 | 1.70 | FAIL (across-run) |
| 512 | 6,759 | 7,177 | 1.06 | PASS | 14.00 | 21.38 | 1.53 | FAIL (across-run) |
| 1024 | 8,941 | 9,961 | 1.11 | PASS | 36.00 | 45.66 | 1.27 | FAIL (across-run) |
| 2048 | 15,450 | 17,427 | 1.13 | PASS | 78.80 | 93.37 | 1.18 | FAIL (borderline; fence 1.15) |
| 4096 | 32,722 | 36,168 | 1.11 | PASS | 299.80 | 324.43 | 1.08 | PASS |

**PRD §2.3 tail-invariance: HOLDS at 7/7 re-measured rungs** — the per-actor
p99/p50 tail stays ≤1.15 everywhere at 9 runs (max 1.13 at 2048), so W15-B's
7/13 actor FAILs were 3-sample noise: typed **PASS-noise-resolution**. The
tail grows monotonically with N (1.01 → 1.13) — a real, in-fence trend, not
flatness — but every rung remains inside the 15% invariant. Residual single-run
outliers (16: one run at 1.16; 2048: one at 1.156) no longer flip the verdict;
under a strict all-9-runs-must-pass reading the FAIL set would be {16, 2048},
typed and disclosed rather than hidden. The across-run whole-VM wall is a
**real tail at 16/128/256/512/1024** (ratios 1.22–1.70; 2048 borderline 1.18):
cold-boot jitter across fresh VMs, not a per-actor scheduler tail, and not the
§2.3 per-actor metric. Receipts-not-prose: this verdict is computed from the 63
appended jsonl rows, replayable via `python3` over `bench/scvd.jsonl`
(`wave: "w15c-tail9"`).
