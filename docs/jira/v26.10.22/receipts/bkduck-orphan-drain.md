# BK-DUCK — orphan drain (duckdb load-court leaks)

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22 07:21-07:24 PDT · **Repo**: **/Users/sac/smalt** (ops lane; this receipt only)
- Prescription source: BK-QMON (`docs/jira/v26.10.22/receipts/bkqmon-window.md`, verdict BENCH-WINDOW-BLOCKED)

## 1. Verification (before)

```
$ ps -o pid,ppid,lstart,%cpu,command -p 24790,25653,26577
  PID  PPID STARTED                       %CPU COMMAND
24790     1 Thu Oct 22 05:40:44 2026     228.0 /opt/homebrew/bin/duckdb -csv -noheader -c CREATE TABLE t AS SELECT 1 AS x;\012WITH RECURSIVE inf(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM inf) SELECT MAX(x) FROM inf;\012
25653     1 Thu Oct 22 05:41:02 2026     243.5 (same infinite recursion)
26577     1 Thu Oct 22 05:41:29 2026     262.0 (same infinite recursion)
$ uptime (07:21)
load averages: 82.39 89.19 95.10
$ lsof -p <pid> (all three): cwd = /Users/sac/smalt; no .db/.csv/.wal REG files open —
only the binary txt + dyld. Pure CPU spin, writing nothing.
```

Orphan test (tree-aware law): all three have **PPID 1** — reparented to launchd,
no live lane harness in the parent chain. Started 05:40-05:41, ~1h45m runtime,
no lane claims them. **Confirmed orphans.** Combined ~733% CPU.

## 2. Drain

```
$ kill 24790 25653 26577   (SIGTERM; all three exited within 3s)
$ ps -o pid,command -p 24790,25653,26577
  PID COMMAND  (no rows — all gone)
$ uptime (07:22)
load averages: 78.55 87.88 94.50   (1-min falling: 82.39 -> 78.55)
```

## 3. Post-drain load

```
$ uptime (07:23, after 90s settle)
load averages: 43.07 73.11 88.07   (1-min: 78.55 -> 43.07; the ~750% drop is visible)
$ uptime (07:24)
load averages: 47.85 72.79 87.69
```

1-min load roughly halved within 2 minutes of the kill. The residual
(~43-48 on 16 cores) is live lane traffic: active mix-test beams
(kafka_exp4/kafka_wire, eplaw/expl11r3/vm_zero_growth), az1 kafka_probe
consumers, and a bkprofv private-block substrate (ports 39550-39559) —
all tree-verified as live lane work, kept per the same law.

## 4. Orphan census (post-drain)

```
$ ps aux | grep -iE 'duckdb|WITH RECURSIVE'   -> zero rows
$ ps -axo pid,ppid,etime,%cpu,comm | awk '$2==1 && $4+0>50'
   350     1 01-21:59:25  98.1  mds
   577     1 01-21:59:14 174.3  mds_stores
```

- Zero duckdb / recursive-duckdb processes remain.
- The only reparented high-CPU processes are `mds`/`mds_stores` (macOS
  Spotlight metadata, running since boot Tue 09AM) — OS subsystem, not lane
  orphans; typed and NOT killed.
- All remaining high-CPU beams/python trace to active lanes (kafka courts,
  az1 probes, bkprofv substrate). No further orphans found; nothing else killed.

## 5. b4 disposition (from BK-BQUIET receipt)

BK-BQUIET re-measured b4 messaging as **FAIL (load-confounded)** — "stays
SUSPECT-PERMANENT, louder": SB sends 0/2000 with 3 errs while CBS put-tokens
returned 200 x1717, killed after ~25 min of phase-(b) churn. Its stated close
condition: "the messaging owner must re-witness on a genuinely quiet machine
before any flip."

**Window status**: the dominant orphan mint source is now gone, but the machine
is NOT yet quiesced (load 43-48 vs 16 cores; multiple live lane beams still
minting at 07:24). The window is **opening, not open** — b4's re-witness should
wait until `just quiet-check` passes (load + port + beam census), or be taken
load-typed honestly as BK-BQUIET did.

## Falsifier / close condition

Falsified if any of 24790/25653/26577 is still alive now, or if 1-min load did
not fall materially after the drain (both refuted by the embedded output above).
Close: BK-QMON's named primary minters removed; residual load attributed to
live lanes and typed.
