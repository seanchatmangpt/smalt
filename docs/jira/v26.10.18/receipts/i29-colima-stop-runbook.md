# I29 — Colima-Stop Runbook (AZB-23 quiet-machine transition)

Context: solo(no execution; typed recommendation only)

Standing: **TYPED_RECOMMENDATION** (no execution; Context: solo)
Date: 2026-10-18
Inputs: `i29-port-census.md` (colima ssh mux 61023 holds 9443/8443/5672), `i29-docker-reclaim.md`,
azb-17 (PARTIAL_ALIVE, docker-disk-exhausted blocker), azb-18 (STAGED, container leg not executed),
azb-22 (RED — ring blocked on shutdown defect; burn machinery green where witnessed).

## 1. Live container census (docker ps, exit 0, 2026-10-18 22:42)

| Container | Image | Status | Owner lane | Shutdown safety |
|---|---|---|---|---|
| dbg-id, dbg-id2 | fc8742091371 | Up 33-34 min | debug/identity probe lane | Safe — ephemeral probes, recreated per probe run, no persistent state |
| kind-smalt-control-plane, kind-smalt-worker | kindest/node:v1.34.0 | Up ~1 h | smalt kind-cluster lane | Safe — kind nodes are disposable; manifests live in the repo, not the node |
| smalt-burn-smalt-burn-integration-{1..8} | smalt:local | 5 Up, 3 Exited(0) | azb-22 / parallel-matrix burn lane (docker/burn/parallel-matrix.sh) | Safe-with-precondition — ephemeral per-cycle containers (3 already exited 0 on their own); must reach quiescence before colima stop |
| act-sock-relay | alpine/socat | Up 8 h | socat relay for the act lane | Safe — stateless TCP relay; recreate is one command from the owning lane script |

All 12 restartable. Local Volumes: 2, ACTIVE, 19.8 GB — volumes live on the VM disk and
survive stop/start, so **no container state is lost by a colima stop/start cycle**. The only
hazard is stopping the VM under a live build or live burn cycle — the quiescence precondition
below covers exactly that.

### Disk picture

`docker system df`: Images 28.94 GB (20.08 GB reclaimable, 69%); Containers 19 MB;
Build Cache 14.32 GB (42 entries, 0 reclaimable while live); Volumes 19.8 GB.
Host `/` has 23 Gi free — the "100% full" is the colima VM disk, not the host.
Levers: `docker builder prune -a -f` = ~14.3 GB (cache only, lanes re-fetch on next build);
`docker image prune -a -f` = ~20 GB but deletes smalt:local + kind node images
(lane-destroying; POST-azb-18-leg only, or defer to colima stop which suspends without deleting).

## 2. Stop sequence (order is load-bearing)

Core conflict: azb-18's container leg needs docker UP; court-x2's quiet-machine precondition
needs colima DOWN. Same VM, mutually exclusive states — sequence, never overlap.

### P0 — no in-flight docker-lane receipts pending

State at writing: azb-17 PARTIAL_ALIVE and parked (its follow-up repro container could not
start — docker-disk-exhausted — nothing in flight); azb-18 STAGED (container leg not started,
nothing in flight); azb-22 RED with ring re-run gated on the shutdown-defect repair, and its
burn containers are the ones visible in `docker ps`. No lane has a receipt pending on a
currently-executing docker run.

Gate-time re-check (read-only), required before P1:
```
docker ps --filter status=running --format '{{.Names}}'
# acceptable residue: act-sock-relay, dbg-id, dbg-id2 (idle relays/probes)
# any smalt-burn-* still Up  => NOT quiesced, hold
```

Rollback: none needed — this is an observation step; holding is the rollback.

### P1 — builder prune (clears azb-17's blocker, funds azb-18's rebuild)

Precondition: P0 shows the smalt-burn-* containers Exited/removed.
```
docker builder prune -a -f             # ~14.3 GB released (42 cache entries)
docker system df                       # re-read: build cache ~0
```
This alone gives azb-18's image rebuild ~14 GB headroom and unblocks azb-17's repro container.
Timeline: ~1-5 min. Rollback: none — cache is a pure cache; lanes rebuild on demand. If the
post-prune headroom is still short of azb-18's need, escalate to
`docker image prune -a -f` (~20 GB) ONLY after the azb-18 leg decides it cannot proceed —
it destroys smalt:local, forcing a full rebuild before any burn leg.

### P2 — azb-18 leg FIRST, then colima stop (why)

azb-18 is STAGED-but-ready: it needs docker UP for image rebuild + container leg, and its
receipt is an input to the AZB-23 court window. court-x2 needs colima DOWN. Stopping colima
first would BLOCK azb-18 until restore — a needless block of a dependent receipt. Run the
azb-18 leg now, on the headroom P1 just released:
```
# per azb-18-cgroup-soak.md replay section (image build + staged container leg)
docker system df                       # watch headroom during build
```
Timeline: azb-18 leg est. minutes-to-tens-of-minutes (image rebuild dominates).
Rollback: fail the leg with a typed receipt (azb-18 stays STAGED); colima stop remains
lawful — court-x2 does not depend on azb-18 passing, only on the leg not being mid-flight.

### P3 — colima stop → verify → quiet-check → court-x2

Precondition: P2 complete (no docker lane mid-flight) and P1 prune done.
```
colima stop                            # graceful suspend; ssh mux 61023 exits
lsof -nP -iTCP:9443 -iTCP:8443 -iTCP:5672 -sTCP:LISTEN   # MUST exit 1 (ports free)
colima list                            # default: Stopped
```
If lsof still shows ssh 61023: do NOT kill it (FOREIGN live infra per port census);
`colima stop --force` is the only lawful retry. If that fails, mark court-x2
BLOCKED[STOP-FAILED] and halt — no pattern-pkill, no port sweep of the mux.

Then the court window:
```
eval "$(scripts/dev_env.sh)"           # SSL_CERT_FILE + SAS key (court precondition)
just quiet-check                       # required before any court (repo convention)
just court-x2                          # ~8 min
```
Timeline: stop ~10-30 s, verify seconds, quiet-check per its recipe, court-x2 ~8 min.
Rollback: `colima start` at any point; a failed court-x2 receipt is a typed failure, not a
rollback — the machine returns to pre-transition state via P4 regardless.

### P4 — restore

```
colima start                           # VM resumes; mux respawns and re-holds 9443/8443/5672
lsof -nP -iTCP:9443 -sTCP:LISTEN       # exit 0, ssh mux = forwards restored
docker ps                              # containers stopped-but-present; restart lanes as needed
```
kind nodes and burn containers come back via their owning lane scripts, not automatically.
Timeline: ~30-60 s. Rollback: none needed (this IS the rollback for P3).

## 3. Estimated timeline

| Step | Duration | Cumulative |
|---|---|---|
| P0 gate re-check | <1 min | 0:01 |
| P1 builder prune | 1-5 min | 0:06 |
| P2 azb-18 leg | ~10-30 min (rebuild-dominated) | 0:36 |
| P3 colima stop + verify | ~1 min | 0:37 |
| P3 quiet-check + court-x2 | ~10 min | ~0:50 |
| P4 colima start + lane restarts | ~5 min | ~1 h |

Total docker-lane downtime for the burn lanes: ~20 min (P3+P4). Volumes and images are
untouched throughout — only the build cache is consumed.

## 4. Go/no-go summary

- GO for P0→P1 now (nothing in flight, prune is non-destructive, unblocks azb-17).
- GO for P2 (azb-18 leg) once P1 confirms ~14 GB headroom.
- GO for P3 (colima stop → court-x2) only after P2 lands or is typed-FAILED-staged.
- NO-GO for: `docker image prune -a -f` before P2 completes; killing ssh mux 61023;
  colima stop with any smalt-burn-* container Up; pattern-pkill of any beam.

## 5. Quiesce prep (post-azb-18-leg, 2026-10-18)

Context: solo(gate re-check + P1-strong attempt on live VM; no colima stop, no image/volume deletes)

P0 gate re-check (`docker ps --filter status=running --format '{{.Names}}'`):
smalt-burn-* containers: **zero present** (leg finished; containers removed cleanly).
Residue = runbook-acceptable set only: `act-sock-relay`, `dbg-id`, `dbg-id2` (idle probes/relay).

P1-strong executed:
```
docker builder prune -a -f
Total:	0B
exit=0
```
**Freed: 0 B.** Typed reason: all 24 build-cache entries (7.659 GB) are ACTIVE — created
~45 min ago by the azb-18 leg's image rebuild (`smalt:local` and `smalt-burn` image timestamps
2-4 min before prune); `builder prune -a` only removes cache not backing a live image. The
runbook's ~14.3 GB figure predated the leg's rebuild; that older cache was already consumed
or superseded. No further prune is lawful here without deleting images (P1-escalation is
gated on azb-18 declaring it cannot proceed — leg landed, so NO-GO).

Post-state:
```
docker run --rm busybox df -h /
Filesystem      Size  Used Available Use% Mounted on
overlay          58.9G   40.0G     16.4G  71% /
docker system df: Build Cache 24/24 ACTIVE, 7.659GB, 0B reclaimable;
Images 6 total, 22.11GB (20.63GB reclaimable — smalt:local 7.38GB + smalt-burn 2.19GB are
the leg's fresh builds, retained per NO-GO above)
```
VM free space: **16.4G available** (71% used) — enough headroom for the P3 court window;
no builder-prune escalation needed.

dbg-id / dbg-id2: **still present, still disposable** (debug/identity probe lane, ephemeral,
no persistent state). Report-only per lane contract — not removed. They may be reaped with
`docker rm -f dbg-id dbg-id2` at P3 if the operator wants a strictly idle VM before colima stop;
the runbook's P0 already classifies them as acceptable residue, so leaving them is lawful.

Standing: PARTIAL_ALIVE (gate verified live; P1-strong executed but reclaimed 0B —
typed-negative, not a failure; headroom confirmed via busybox df)
