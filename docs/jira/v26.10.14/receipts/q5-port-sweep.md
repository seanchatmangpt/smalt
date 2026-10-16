# Q-5 Port Sweep Receipt — Active Scavenger Pass

Date: 2026-10-15 20:35–20:42 PDT · Lane: Q-5 (finish-support) · Subject: /Users/sac/smalt @ main (518b31a working tree)
Falsifier: `lsof -nP -iTCP:{9443,9444,8443,5672,5673} -sTCP:LISTEN` returns nothing; `just substrate-status` lock FREE.

## 1. Killed orphans (evidence recorded before each kill)

| pid | cmdline | started | age at kill | evidence |
|---|---|---|---|---|
| 39934 | beam.smp — leaked substrate (`mix run --no-halt`, amqp 5672 / eh 5673 / arm 49409 / tls 50017 / egress 49735) | 19:48:29 | 47 min | held canonical 5672+5673; registered owner `substrate.pid`=33615 dead (`kill -0` fails); lock file had zero holders; no /tmp lane receipts; per substrate.sh ownership contract the substrate outlives its registered owner only as a leak |
| 59092 | beam.smp — `Smalt.Hw.VirtualSerial` PTY harness (`SMALT_HW_PTY`, `Process.sleep(:infinity)`) | 20:05:29 | 30 min | PPID 1 (parent pytest dead); zero LISTEN sockets in whole tree (tree rule); beyond 30-min idle threshold |
| 59369 | beam.smp — PTY read/echo loop test fixture (`SMALT_HW_PTY`, `sleep(:infinity)`) | 20:05:57 | 30 min | PPID 1; zero LISTEN in tree; parent pytest gone |
| 63584 | beam.smp — PTY one-shot echo (`PTY` env, `sleep(3000)` then idle) | 20:12:14 | 23 min | PPID 1; zero LISTEN in tree → orphan by tree rule regardless of age |
| 67574 | epmd -daemon | 18:36:06 | 2h | `epmd -names` returned zero registered nodes (stale socket, no distributed beams on host) |

All five killed with SIGTERM; none required SIGKILL (verified dead within 3 s).
Left alive (private-port lanes, live listeners, fresh): 61598 (60709–60714), 65848 (63929–63934), 75743 (45672/45673/48443/49443/49444), plus in-flight lane boots 80988/81390/82188. Transient lock holders 82179/82181 and 83837/83839 observed mid-boot (<90 s window) and correctly not killed; both released on their own.

## 2. Port map after sweep

| port | state |
|---|---|
| 9443 | free |
| 9444 | free |
| 8443 | free |
| 5672 | free |
| 5673 | free |

`just substrate-status`: ports 9443/9444/5672/5673 free, substrate DOWN, **lock FREE (flock -n succeeds)**, exit 0.
Remaining listeners on host: live private-port lanes only (61598, 65848, 75743, 80988, 81390, 82188) plus non-smalt processes (postgres 5432, Loom, Cursor).

## 3. Reusable artifact

`scripts/port_sweep.sh` (executable) — same tree-aware guard as `scripts/substrate.sh`
(`tree_listening` over flock→mix→beam 2-level descendants), plus:
- 2-minute fresh-process grace (skip in-flight boots),
- stale-epmd detection (zero registered nodes),
- stale `substrate.pid` owner check,
- dry-run by default, `-y` to kill, exits 1 if any canonical port still held post-sweep.

Dry-run verified post-sweep: reports "nothing to kill", all five canonical ports free, exit 0.

## 4. Verification transcript

```
$ just substrate-status
[STATUS] port 9443: free ... port 5673: free
[STATUS] substrate DOWN
[STATUS] lock FREE (flock -n succeeds)
$ for p in 9443 9444 8443 5672 5673; do lsof -nP -iTCP:$p -sTCP:LISTEN; done
(no output — all free)
$ scripts/port_sweep.sh   # post-sweep dry run
port 9443: free ... port 5673: free; nothing to kill; exit 0
```

Standing: ALIVE for the sweep itself; F-6/F-8 now get clean 9443/9444/8443/5672/5673 first-try.
