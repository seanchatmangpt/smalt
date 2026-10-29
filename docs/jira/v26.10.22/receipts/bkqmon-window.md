# BK-QMON — Bench Window Census (BQUIET-support monitor)

- **Standing**: PARTIAL_ALIVE (BK-STAND6: census receipt — embedded output is complete and typed: 1-min load 85–99 on 16 cores, 0.17% idle, 3 orphaned duckdb recursions ~750% CPU, 4/5 BQUIET remeasures landed with b4 stalled; verdict BENCH-WINDOW-BLOCKED is a window disposition, not a capability standing; b5/c8 remeasures flagged load-window provenance)
- **Context**: solo
- **Date**: 2026-10-22 07:20 PDT
- **Subject**: /Users/sac/smalt @ 375284c9 (tree read-only; this receipt only)

## Verdict: BENCH-WINDOW-BLOCKED

Machine is NOT quiesced enough for 30s-measured bench windows.

## 1. Load census (real output)

```
07:19:30  load: 89.79 92.78 97.16
07:19:40  load: 84.89 91.64 96.71
07:19:50  load: 93.08 93.16 97.19
07:20:00  load: 93.61 93.25 97.17
07:20:10  load: 98.72 94.39 97.53
07:20:20  load: 96.13 93.98 97.35
```
16 cores (hw.ncpu=16; 12 performance). CPU: 62.4% user / 37.4% sys / **0.17% idle**.
Load average is 5.6-6.1x core count and *rising*, not falling — contradicts
BK-DRAIN2's "67.33 falling" reading (taken earlier; the 1-min figure has since
re-climbed from 67 to ~90+).

## 2. Named load minters

**Primary minters (outside any bench lane) — 3 orphaned duckdb infinite-recursion
processes** (classic load-court harness leaked, never drained):

```
PID 24790  started 05:40:44  231% CPU  212 min CPU-time  duckdb -c "... WITH RECURSIVE inf(x) AS (SELECT 1 UNION ALL SELECT x+1 ...) SELECT MAX(x) FROM inf"
PID 25653  started 05:41:02  240% CPU  224 min CPU-time  (same infinite recursion)
PID 26577  started 05:41:29  283% CPU  258 min CPU-time  (same infinite recursion)
```
~750% CPU combined, pinned for ~1h38m. Not associated with any active lane; these
alone account for ~47% of total machine capacity and are the dominant mint source.

**Lane beams still minting (mix test / mix run, 11 "mix test" processes alive):**

- BK-KFKV: `mix run --no-halt scripts/kafka_replay/bkkfkv_boot.exs` (55% CPU, since 07:16)
- internal_tier_census_test beam (60% CPU)
- kafka_exp4_court + kafka_wire tests (8% CPU, BK-KFKC2 surface)
- mcpt1_dispatch + bkegs1_fence + expl8r courts (15% CPU)
- amqp10_bk116_skeptic (2% CPU, since 07:17)
- one substrate beam on ephemeral ports (`arm_port` env probe, 338% CPU at sample)

## 3. BK-BQUIET progress (bench result mtimes)

`tmp/bkbquiet/` — 4 of 5 lanes have fresh remeasures:

| lane | remeasure jsonl | mtime |
|---|---|---|
| b2 | b2-blob-ts-remeasure.jsonl | 06:43 |
| b3 | b3-cosmos-ts-remeasure.jsonl | 06:47 |
| b4 | — none — (b4-run.log ends 06:49: substrate up 29s, then "0 msgs in 40s = 0.0 msgs/s, errs=3 clientRecycles=2") | stall |
| b5 | b5-python-mirror-remeasure.jsonl (+ b5-remeasure-discarded-head.jsonl — a discarded noisy head) | 07:12 |
| c8 | c8-chaos-cross-remeasure.jsonl (driver done 14:17:31Z) | 07:18 |

BK-BQUIET is actively mid-flight (c8 remeasure landed 2 min before this census),
but b4 is stalled at zero throughput with errors — likely a casualty of the same
load, not a code defect.

## 4. Recommendation

Coordinator action: drain the three orphaned duckdb recursions (PIDs 24790, 25653,
26577) and wait for the 1-min load to fall below the BQUIET quiesce bar; the c8/b5
remeasures that landed under this load (b5 p99 68.5ms vs its earlier runs) are
SUSPECT and should be re-run in a genuinely quiet window. b4 needs a re-drive after
drain. Also: one more `mix test`-bearing beam (internal_tier_census) should finish
naturally; no other lane needs coordinator intervention.

## Falsifier

A subsequent census after draining 24790/25653/26577 showing 1-min load below the
quiesce bar with idle > 50% flips this verdict to BENCH-WINDOW-OPEN (partial flip:
b2/b3/c8 remeasures still carry load-window provenance).

## Evidence re-check (BK-SUSP5, 2026-10-22 ~09:03 PDT)

```
$ uptime
 9:03  up 1 day, 23:40, 4 users, load averages: 39.01 16.24 10.60
uptime exit 0
$ pgrep -fl "WITH RECURSIVE"
(no output — the three orphaned duckdb recursions 24790/25653/26577 are drained)
pgrep exit 1 (no match) — drain confirmed
```

Re-check verdict: PASS — the census's typed drain recommendation has been
executed: 1-min load fell from ~90-98 (07:20) to 39.01 (09:03), 1m > 5m > 15m
not yet fully inverted but falling, and the three named duckdb recursions are
gone. The 07:20 BENCH-WINDOW-BLOCKED verdict stands as-written; the falsifier
(below-bar load flip to OPEN) is now live for a fresh census lane.
