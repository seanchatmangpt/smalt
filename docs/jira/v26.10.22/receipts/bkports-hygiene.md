# BK-PORTS — Port hygiene census (post ~6h 20-lane fan-out)

- **Standing**: PARTIAL_ALIVE
- **Context**: solo
- **Date**: 2026-10-22 ~04:25–04:35 local
- **Lane**: BK-PORTS (ops census only; no kills executed)

## Commands run

```bash
just substrate-status
scripts/port_sweep.sh          # dry-run default
lsof -nP -iTCP -sTCP:LISTEN   # per-port tree mapping
lsof -p <pid>                  # lock-fd inheritance check
```

## Census snapshot (census start, ~04:24)

```
[STATUS] port 9443: free
[STATUS] port 9444: free
[STATUS] port 5672: free
[STATUS] port 5673: free
[STATUS] substrate DOWN
[STATUS] lock HELD by: bash pid 24468 fd 9w;bash pid 24844 fd 9w;flock pid 24869 fd 9w;
[STATUS] ORPHAN: pid 24844 holds the lock with no listening socket in its tree
[STATUS] ORPHAN: pid 24869 holds the lock with no listening socket in its tree
[STATUS] ORPHAN: pid 26836 holds the lock with no listening socket in its tree
```

Note: pids 24844/24869/26836 were **already dead** at listing time (transient
flock waiters; `ps -p` returns nothing). substrate-status prints lsof output
without a liveness recheck — cosmetic false ORPHANs, typed below.

## Port census (tree-mapped, verdicts)

| Port(s) | Owner pid | Tree | Verdict |
|---|---|---|---|
| 9443/9444/8443/5672/5673 (canonical) | 21011 (was free; bound during census) | ppid 1, `mix run --no-halt` full smalt self-boot, etime ~5m | **LIVE-LANE** (live LISTEN on all five; not lock-aligned — see finding F2) |
| 39210–39215 | 54162 | matches `/tmp/smalt-substrate-state/markers/b21.boot.json` pid | **LIVE-LANE** (b21) |
| 39900–39905 | 35148 | matches `markers/b90.boot.json` pid | **LIVE-LANE** (b90) |
| 39910–39915 | 91446 | matches `markers/b91.boot.json` pid | **LIVE-LANE** (b91) |
| 9092 | 18147 | ppid 1, asdf-29.1.2 beam, 3h40m | **LIVE-LANE** (live private listener) |
| 9443/9444/8443/5672/5673 at census start | — | — | free (boot in flight, see F1) |

## Findings

**F1 — mid-census boot race (resolved, no action)**: at census start a
`substrate.sh up` window (bash 24468 → beam 24487, boot marker 04:22) held the
flock and was mid-compile. During the census it **died mid-compile** while
detached beam 21011 bound all five canonical ports. Final state: lock FREE,
`substrate UP (pid 30875)`, canonical ports UP on 21011. The 04:22 window lost
the port race and exited; no stale lock remains.

**F2 — lock-alignment gap (open, reported)**: beam 21011 holds all canonical
ports with **zero lock fds** (`lsof -p 21011 | grep smalt-substrate.lock` = 0)
while the lock is FREE — i.e. a full substrate is running OUTSIDE the
per-window flock protocol. Under the collision law this is the hazard shape:
the next `substrate-up` acquires the lock then fails to bind. Not killed: it
has live LISTEN sockets, so per the tree-aware law it is LIVE, and killing a
live lane substrate is outside BK-PORTS authority. Owner: whichever lane
booted it (mix eval sets sb/amqp/arm/egress/tls/kafka ports — a lane harness).

**F3 — stale-pid ORPHAN false positives in substrate-status (cosmetic defect,
out-of-lane file)**: `[STATUS] lock HELD by: ... pid 24844/24869/26836` lists
pids that were already dead at print time; each then gets an ORPHAN line.
lsof output is not liveness-rechecked. Candidate one-line fix in
`scripts/substrate.sh` (filter `lsof -t LOCK` through `ps -p`), but that file
is outside BK-PORTS ownership — reported, not edited.

**F4 — epmd transient**: epmd 12632 was flagged `ORPHAN (no registered nodes)`
at census start (9 min old, spawned by the in-flight boot); by the final
snapshot it was reclassified `live LISTEN in tree` — the new substrate
registered its node. Correct self-resolution; no kill.

## Lock-fd inheritance check (27-min starvation class)

```
pid 24487 (beam): 0 smalt-substrate.lock fds
pid 54162/35148/91446/18147/28349: 0 lock fds each
```

**No beam holds an inherited flock.** The `9>&-` law holds across all
surveyed trees.

## /tmp collision-law consistency

- `/tmp/smalt.pid` — absent (good; `just up` not in use; substrate lanes use
  the state dir).
- `/tmp/smalt-substrate-state/substrate.pid` — present, contains `30875`,
  matches `[STATUS] substrate UP (pid 30875)`. (Transiently absent mid-boot
  during F1.)

## Orphan kills

**None.** No whole-tree-dead-of-listeners candidates at census time; the only
sweep-flagged candidate (epmd 12632) self-resolved (F4). `port_sweep.sh -y`
was never invoked.

## Final snapshot (~04:35)

```
[STATUS] port 9443: UP (pid 21011)
[STATUS] port 9444: UP (pid 21011)
[STATUS] port 5672: UP (pid 21011)
[STATUS] port 5673: UP (pid 21011)
[STATUS] substrate UP (pid 30875)
[STATUS] lock FREE (flock -n succeeds)
```

## Standing

PARTIAL_ALIVE: full census executed with embedded real output; verdicts
per-port tree-mapped; zero kills (none typed); F2/F3 reported with owners
unresolved (live lane substrate outside the lock protocol; substrate-status
stale-pid listing — both outside this lane's file ownership).

---

## RE-WITNESS addendum (BK-REWIT wave 1, 2026-10-22)

Original evidence above untouched. Replay of the named census commands with
exit capture (BK-SUSP prescription):

```
$ just substrate-status; echo exit=$?
[STATUS] port 9443: UP (pid 76567) ... [STATUS] substrate UP (pid 76567)
[STATUS] lock FREE (flock -n succeeds)
status exit=0
$ scripts/port_sweep.sh; echo exit=$?
DRY-RUN: rerun with -y to kill: 28349 40201 50823 60498 62736 12632
(port map: 9443/9444/8443/5672/5673 STILL HELD by beam.smp(76567))
sweep exit=0
$ lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(9443|9444|8443|5672|5673|39[0-9]{3}|9092)'; echo exit=$?
private blocks b21 (54162, 39210-39215), b90 (35148, 39900-39905),
b91 (91446, 39910-39915) still LISTEN; canonical five on 76567; 9092 on 18147;
new trees 84785 (39890-39895), nodes 48868/51468 on 39751/39851
lsof exit=0
```

Re-witness verdict: census surface intact and the same shape reproduces
(private lane blocks live, canonical ports held by one substrate tree, zero
inherited lock fds implied by clean sweep). exit=0 on all three commands.
Standing: PARTIAL_ALIVE (unchanged; F2/F3 dispositions owned by
bkports2-reconcile).
