# BK-ZOMB — reparented-process census + duckdb source hunt

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22 08:15-08:30 PDT · **Repo**: **/Users/sac/smalt** (census lane; read-only except this receipt)
- Prescription source: BK-DUCK (`receipts/bkduck-orphan-drain.md`)

## Verdict

1. **No second duckdb-class leak exists right now**: zero `duckdb`/`WITH RECURSIVE`
   processes are alive (grep of the live process table is empty). The remaining
   PPID=1 population is beams/graphlaw-run/azurite/lima — none spinning.
2. **23 typed zombie-candidates** (PPID=1, zero CPU, zero LISTEN sockets, cwd
   /Users/sac/smalt) — NOT killed (read-only lane); listed in §2 for the ops
   owner to drain on their own authority.
3. **Duckdb source: NOT attributable from disk.** The `WITH RECURSIVE inf` shape
   exists in zero tracked scripts (grep receipts/scripts/docs/tmp: only the
   BK-DUCK/BK-QMON receipts quote it). Typed verdict: an **ad hoc inline `-c`
   synthetic-load probe** run by some lane outside every tracked harness —
   which is exactly why no trap covered it.

## 1. Census method (tree-aware law, same as BK-DUCK)

```
$ ps -axo pid,ppid,command | awk '$2==1' | grep -cE 'beam.smp'   -> 43 beams
$ ps -axo pid,ppid,command | awk '$2==1' | wc -l                 -> 48 total PPID=1
```
Typed per process by: (a) LISTEN socket count via `lsof -nP -p <pid>` (the
private-port lane liveness test from the same-checkout-fanout law), (b) %CPU,
(c) age.

**24 processes = live-lane (kept)**: every beam/azurite/chrome-shell carrying
LISTEN sockets. Spot check:

```
1788 LISTEN=2   2652 LISTEN=11  3089 LISTEN=11  10136 LISTEN=7   14089 LISTEN=11
15125 LISTEN=11 15509 LISTEN=7  15938 LISTEN=11 25419 LISTEN=7   35148 LISTEN=7
38329 LISTEN=11 38894 LISTEN=11 41971 LISTEN=11 54162 LISTEN=7   57431 LISTEN=1
58569 LISTEN=3  59497 LISTEN=7  63245 LISTEN=1  81426 LISTEN=11  82116 LISTEN=11
91446 LISTEN=7  94891 LISTEN=11 96188 LISTEN=11 16880 LISTEN=2
```
(azurite 58569/63245 on blob 10000/10100 = popcorn_demo azurite-spike, live
utility; 57431 chrome-headless listening on its CDP port, popcorn_demo
playwright — kept.)

**macOS-system (kept, named)**: `mds` (PID 350) + `mds_stores` (PID 577) —
Spotlight metadata, up since boot, per BK-DUCK §4.

## 2. Zombie-candidates (PPID=1, cpu=0.0, LISTEN=0) — NOT killed

```
 2763  02:32:24  graphlaw-run --wasm .../gws18-wasm-snapshot-1792670107951.wasm --expect-blake3 2ab5cf43... --hang
 4338  10:24:42  graphlaw-run --wasm .../gws18-wasm-snapshot-1792641769798.wasm --hang
 5450  01:03:01  beam.smp (asdf 29.1.2)
10979  14:23:57  graphlaw-run --wasm .../graphlaw_wasm.wasm --hang
10980  14:23:56  graphlaw-run --wasm .../graphlaw_wasm.wasm --hang
26004  08:56:43  graphlaw-run --wasm .../gws18-wasm-snapshot-1792647049871.wasm --hang
28349  1-09:46:55 beam.smp (erlmcp otp-28.3.1)
29199  01:44:53  beam.smp (asdf)
33524  03:01:16  bash -c 'cd /Users/sac/smalt; source scripts/bench/lib.sh; bench_boot b1 || exit 124; echo SUBSTRATE-UP...; sleep 100000'
36849  14:02:30  graphlaw-run --hang
37029  14:02:08  graphlaw-run --hang
37681  14:01:33  graphlaw-run --hang
40201  02:58:17  beam.smp (asdf)
41117  03:56:19  graphlaw-run --hang
41263  13:57:37  graphlaw-run --hang
50823  03:41:17  beam.smp (asdf)
51684  02:17:21  beam.smp (asdf)
60498  03:33:40  beam.smp (erlmcp)
62736  03:32:53  beam.smp (erlmcp)
66298  01:23:47  beam.smp (asdf)
82605  01:15:39  beam.smp (asdf)
91204  01:10:13  beam.smp (asdf)
93357  01:59:52  graphlaw-run --hang
98800  07:38     beam.smp (asdf)   <- YOUNG (7 min): typed MAYBE-LIVE (a lane mid-boot between listens); re-check before any drain
98800 excluded from the drain candidate set on the age rule.
```

Three subclasses, typed:

- **12 graphlaw-run `--hang` procs**: hang-court test doubles from the GWS-18
  runner-shim / andon-timeout courts (wasm snapshots under
  `/Users/sac/.cache/tmp/gws18-wasm-snapshot-*.wasm` + the blessed
  `graphlaw_wasm.wasm`). Zero CPU, no socket, oldest 14h. Leaked because the
  spawning court exited without reaping its doubles. Same class as duckdb:
  harness-spawned, survived the harness.
- **10 idle beams** (asdf 29.1.2 + erlmcp otp-28.3.1): reparented, zero CPU,
  no socket. Some may be ERLMCP long-lived services — the erlmcp-rooted ones
  (28349, 60498, 62736) predate this morning; typed SUSPECT, owner = whoever
  runs erlmcp sessions, not drainable by this lane.
- **1 leaked bench harness shell** (33524): `bench_boot b1` succeeded, its
  substrate has since died (0 LISTEN, no children — only `sleep 100000`
  remains at child 33792), and the shell is parked in `sleep 100000`. The
  EXIT-trap in `scripts/bench/lib.sh:113` never fires because the shell never
  exits. Zombie-candidate.

No action taken against any of them: this lane is read-only. Drain authority
sits with the ops owner (BK-DUCK precedent: kill by exact PID after tree-aware
orphan verification).

## 3. Duckdb source hunt (typed result)

```
$ grep -rn "WITH RECURSIVE" docs scripts tmp | grep -v receipts-of-this-class
  -> only BK-DUCK/BK-QMON receipt quotes of the leaked command line
$ grep -rn "duckdb" scripts/ justfile* -> only scripts/bench/sqld8_ingest_baseline.{exs,sh}
  (System.cmd("duckdb", [db, "-c", projection_sql]) — bounded, synchronous,
   waits for exit; cannot orphan)
```

The leaked command (`duckdb -csv -noheader -c 'CREATE TABLE t AS SELECT 1 AS x;
WITH RECURSIVE inf(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM inf) SELECT MAX(x)
FROM inf'`) is a synthetic infinite-recursion CPU burn. It matches **no tracked
harness**. BK-QMON's phrase "classic load-court harness leaked" is correct in
class but wrong in locus: there is no tracked load-court that runs duckdb — so
the spawner was an **untracked, ad hoc inline probe** run by some lane at
05:40-05:41 on 2026-10-22 (three launches ~20s apart — one probe run three
times, likely a load-generation leg of a quiet-window court). The ps history
needed to name the lane is gone; the source lane is **typed UNATTRIBUTABLE
from disk**, not merely unexamined.

## 4. Prevention note (typed; no fix landed)

`scripts/bench/lib.sh` **does** have child hygiene for its own substrate —
`#EXIT-TRAP` at line 111-115 installs `bench_down` on EXIT/INT/TERM (plus fd
9>&- spawn hygiene). The gap is narrower and conventional:

1. **The EXIT-trap pattern only protects what bench_boot spawns.** An ad hoc
   `duckdb -c ... --hang`-style probe typed directly into a lane's Bash tool is
   outside every trap; if the lane session dies, the probe is reparented to
   launchd and burns forever. Prevention is a convention note, not a code fix:
   **any synthetic-load probe must run under a bounded wrapper** (`timeout` /
   `gtimeout`, or `cmd & PID=$!; trap 'kill $PID' EXIT`) — never a bare
   infinite loop with no timeout, in any lane, tracked script or not.
2. **The graphlaw `--hang` doubles subclass is a tracked-court gap**: whatever
   GWS-18/andon court spawns `graphlaw-run --hang` as a test double does not
   reap it on exit. That court lives outside this repo's ownership surface
   (spawns from `/Users/sac/graphlaw`), so typed as **PREVENTION-DEFERRED to
   the graphlaw court owner**, not fixed here (file unowned by this lane).

Nothing edited outside this receipt. Close condition for the class: a drain
pass (ops owner) empties §2, and any future load probe appears in the process
table under a bounded wrapper.

## Falsifier

Falsified if a `duckdb`/`WITH RECURSIVE` process is alive at read time (none
is — empty grep above), or if any §2 entry shows nonzero CPU or a LISTEN
socket (all re-verified zero at receipt time).
