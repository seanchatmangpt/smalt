# I29 — Port-Hygiene Census (pre AZB-23 court-x2)

Standing: PARTIAL_ALIVE (census executed; ports BLOCKED by live colima, no quiet machine)
Context: solo(lsof; substrate-status; port_sweep dry-run)
Date: 2026-10-18

## Command receipts

`lsof -nP -iTCP:9443 -iTCP:8443 -iTCP:9444 -iTCP:5672 -iTCP:5673 -iTCP:9545 -sTCP:LISTEN` (exit 1, holders found):

```
ssh 61023 sac 11u IPv4 ... TCP *:9443 (LISTEN)
ssh 61023 sac 14u IPv4 ... TCP *:5672 (LISTEN)
ssh 61023 sac 18u IPv4 ... TCP *:8443 (LISTEN)
```

9444, 5673, 9545: free (no listeners).

## Classification

| PID | Class | Evidence |
|---|---|---|
| 61023 | FOREIGN (colima ssh mux) | `ssh: /Users/sac/.colima/_lima/colima/ssh.sock [mux]`, ppid=1, cwd incidentally /Users/sac/smalt; holds 9443/8443/5672 via VM forwards; also forwards docker.sock + localhost:2375 |
| 147, 35636, 47965, 99039 (+8 more private-port beams) | LIVE-SMALT private-port lanes | cwd /Users/sac/smalt, LISTEN on 386xx/396xx only — not canonical ports, NOT sweep candidates |

NO DEAD-TREE holders. No beam holds a canonical port.

## Colima dependency check

`colima list`: `default  Running  aarch64  4 CPUs  8GiB  docker` (exit 0). Tree alive:
limactl hostagent (60834), limactl usernet (60830), ssh mux (61023, since 14:37:33 today).
The forwards are live plumbing for a RUNNING VM — the mux is NOT orphaned; killing 61023
would sever docker/containerd socket forwarding for a running colima.

## Substrate status

- `just substrate-status`: 9443 UP (pid 61023 = the ssh mux proxy), 9444 free, 5672 UP, 5673 free; substrate "UP" is a port-proxy reading — the actual holder is colima, not a smalt beam; lock FREE (flock -n succeeds).
- `just status`: no beam on canonical ports; 4+ private-port lane beams alive.

## port_sweep.sh dry-run (exit 1, "nothing to kill")

- 14 beam pids SKIPped: live LISTEN in tree (private-port lanes) or FRESH boot window.
- `STALE pid-file: owner 40499 dead` — a stale owner pid-file exists; sweep law says holders of canonical ports inherit orphan status, but the canonical-port holder is colima (FOREIGN), which the sweep correctly does NOT kill.
- Post-map: 9443/8443/5672 STILL HELD (ssh 61023). Exit 1 = ports blocked, nothing actionable.

## Typed recommendation

- SAFE-TO-SWEEP: none. Zero PIDs qualify under the port_sweep law.
  - 61023 is FOREIGN live colima infrastructure (VM Running) — kill would break docker forwarding, not free the ports lawfully (colima would respawn/hold them again).
  - All beams are live private-port lanes — protected by the tree-aware rule.
- BLOCKED (quiet-machine court-x2): 9443/8443/5672 held by colima ssh mux 61023 while
  `colima default` is Running. Unblock paths (operator decision, NOT executed):
  1. `colima stop` (graceful; frees the mux + forwards), then re-verify lsof, or
  2. run court-x2 with `SMALT_PLANES` on private ports per the plane-profile path —
     court-x2's canonical-port precondition is what fails, not the substrate.
- Hygiene note: stale pid-file owner 40499 (dead) is the only actionable residue; it is
  substrate-state residue, not a port holder, and was left untouched (read-only census).
