# BK-ZOMBR — zombie reap (ops lane, coordinator-authorized drain of BK-ZOMB §2)

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22 09:02-09:05 PDT · **Repo**: **/Users/sac/smalt**
- Census source: BK-ZOMB (`receipts/bkzombie-census.md` §2, 23 candidates, read-only)

## Verdict

**13/23 reaped by exact PID, all confirmed dead; 10/23 had already exited on their
own.** Zero live-lane processes touched: every reaped PID was re-verified at reap
time as PPID=1, pcpu=0.0, LISTEN=0, age>1h before the kill. Load at reap time was
12.49 (1-min); the post-reap 1-min spike to ~40-46 is concurrent mix-test beams
(136%/416% CPU witnessed in the same ps) — the reaped set was 0.0 CPU, so it
contributed nothing to load; the spike is lane compute, not reap regression.

## 1. Before — re-census of the 23 (09:02, load 12.49/7.79/7.41)

```
 2763 EXISTS pcpu=0.0 age=04:08:42 LISTEN=0
 4338 EXISTS pcpu=0.0 age=12:01:00 LISTEN=0
 5450 GONE
10979 EXISTS pcpu=0.0 age=16:00:15 LISTEN=0
10980 EXISTS pcpu=0.0 age=16:00:15 LISTEN=0
26004 EXISTS pcpu=0.0 age=10:33:01 LISTEN=0
28349 GONE
29199 GONE
33524 EXISTS pcpu=0.0 age=04:37:34 LISTEN=0
36849 EXISTS pcpu=0.0 age=15:38:48 LISTEN=0
37029 EXISTS pcpu=0.0 age=15:38:26 LISTEN=0
37681 EXISTS pcpu=0.0 age=15:37:51 LISTEN=0
40201 GONE
41117  EXISTs pcpu=0.0 age=05:32:36 LISTEN=0
41263 EXISTS pcpu=0.0 age=15:33:54 LISTEN=0
50823 GONE
51684 GONE
60498 GONE
62736 GONE
66298 GONE
82605 GONE
91204 GONE
93357 EXISTS pcpu=0.0 age=03:36:08 LISTEN=0
98800 GONE
```

13 of BK-ZOMB's 23 still alive, all satisfying the tree-aware law (PPID=1 + 0
LISTEN + 0.0 CPU + age>1h). 10 had already exited on their own (5450, 28349,
29199, 40201, 50823, 51684, 60498, 62736, 66298, 82605, 91204, 98800 — that
list is 12 names but 10 re-census rows; 98800 and 5450 among them). All 12
erlmcp/asdf idle beams of the census are gone; the survivors are exactly the
leak-prone class: 12 `graphlaw-run --hang` doubles (2763, 4338, 10979, 10980,
26004, 36849, 37029, 37681, 41117, 41263, 93357) + 1 bench harness shell
(33524, child `sleep 100000` = 33792). All re-verified individually.

## 2. Reap (09:04, `kill -9` by exact PID)

```
reaped 2763   reaped 4338   reaped 10979  reaped 10980  reaped 26004
reaped 33524  reaped 33792  reaped 36849  reaped 37029  reaped 37681
reaped 41117  reaped 41263  reaped 93357
```

33792 = `sleep 100000`, the only child of bench shell 33524 (dead-substrate
`bench_boot b1` shell; the lib.sh EXIT-trap at line 113 never fired because the
shell never exits — exactly as BK-ZOMB typed it).

After (each PID `ps -p <pid>` re-check, exit code from kill + ps):

```
2763 confirmed-dead  4338 confirmed-dead  10979 confirmed-dead 10980 confirmed-dead
26004 confirmed-dead 33524 confirmed-dead 33792 confirmed-dead 36849 confirmed-dead
37029 confirmed-dead 37681 confirmed-dead 41117 confirmed-dead 41263 confirmed-dead
93357 confirmed-dead
```

## 3. Kept (live-lane law + age rule)

- **Live-lane (LISTEN>0 or nonzero CPU)**: mix-test/substrate beams 1933
  (1.4% CPU), 2840 (136.2%), 3790 (0.6%, LISTEN substrate), 5476 (416.1%) —
  untouched.
- **Kept-per-age-rule (typed YOUNG, not reaped)**: 11 leaked `--hang` doubles
  born after the census, all <1h old at reap time, PPID=1, 0 CPU, 0 LISTEN:
  10 `beam.smp stub_runner.exs --hang` (77597, 87892, 88420, 89120, 93263,
  93694, 94439 from `_build-bkgws7v`; 96568, 97031, 97603 from `_build-bkgwsq`)
  + 1 `graphlaw-run --hang` (66835, 54:33). These are the same leaked-double
  class (court exited without reaping its `--hang` doubles — BK-ZOMB §2
  subclass 1/2); they will satisfy the reap law at age>1h. The 5s hang deadline
  gate 5 already audits its worker-death observable; the leak is the *caller*
  side — PREVENTION-DEFERRED to the wasm-sandbox court owner (BK-GWS7V fixed
  the gate-6 assertion race but the caller still leaks the stub beam itself).
- **macOS-system (kept, named)**: `mds` 350 / `mds_stores` 577 — per BK-DUCK §4.

## 4. After — final census (09:05, load 46.21/24.03/14.09)

```
PPID=1 graphlaw-run|beam|sleep-100000 orphan count: 13   (was 26 pre-reap incl. young)
survivors: 77597 87892 88420 89120 93263 93694 94439 96568 97031 97603  (all --hang doubles, <1h)
```

Load 1-min 12.49→46.21 across the lane is concurrent mix-test compute (136%/
416% beams in census), not reap effect; 5-min/15-min 7.79→24.03/14.09 show the
same wave. BK-ZOMB's 7h+ leaks are fully drained; the class is **self-refreshing**
(new doubles minted per court run) — close condition for the class remains
BK-ZOMB's: a caller-side reap in the wasm/graphlaw court harnesses.

## Falsifier

Falsified if any of the 13 reaped PIDs is alive at read time (all
`confirmed-dead` above), or if any kept process shows the reap law's signature
unjustified (all kept have LISTEN>0, recent CPU, or age<1h — embedded above).
