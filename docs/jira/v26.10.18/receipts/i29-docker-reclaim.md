# i29-docker-reclaim — AZB-18 cgroup soak disk reclaim attempt

Date: 2026-10-18
Context: solo(docker-reclaim leg; no containers disturbed, no daemon restart)
Standing: BLOCKED (safe-reclaim scope exhausted; coordinator+operator action required)

## Command / output

```
docker system df
Images         4   2   31.18GB   29.7GB (95%)
Containers     5   5   3.961MB   0B (0%)
Local Volumes 23   2   22.71GB   2.914GB (12%)
Build Cache   51  51   17.49GB   0B
```

Reclaim steps, in prescribed order:

1. `docker builder prune -f` -> `Total: 0B` (all 51 cache entries ACTIVE —
   in use by the live dbg-id/dbg-id2 builds minutes old)
2. `docker image prune -f` (dangling only) -> `Total reclaimed space: 0B`
   (the one `<none>` image 7416a61b42b1 is kindest/node, backing the two
   RUNNING dbg containers — not removable without disturbing them)
3. `docker ps -a --filter status=exited` -> empty. Zero stopped containers.
   Running set: dbg-id, dbg-id2, kind-smalt-control-plane, kind-smalt-worker,
   act-sock-relay — all protected classes per task (kind nodes, socat relay)
   plus two live burn debug containers.

## Free-space verification

`docker run --rm busybox df -h /` (probe image removed afterward):

```
Filesystem  Size   Used Available Use% Mounted on
overlay    58.9G  58.5G      0    100%  /
```

Docker VM root is 100% full — 0 bytes available. Host side: Docker.raw is
32G sparse at
`~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw`;
colima profile disk=60GiB, host `/` has 40Gi avail. The ceiling is the VM
disk (60GiB provisioned, 58.5G consumed), not the host APFS volume.

## Why BLOCKED

- No headroom for a ~1-2GB smalt-burn image build; a build will ENOSPC.
- Remaining large consumers are all either RUNNING-container-backed
  (kind nodes + dbg containers + their 10.24GB/9.56GB volumes, links=1) or
  out of authorized scope (22.71GB of act-* volumes, 2.914GB unreferenced —
  volume deletion was not in the safe-reclaim order).

## Unblock options (coordinator+operator territory)

a) `docker builder prune -a -f` AFTER dbg-id/dbg-id2 finish (est. up to
   ~17GB, the build cache is the single largest reclaimable pool);
b) enlarge colima disk (`colima start --edit`, disk 60GiB -> 100GiB, requires
   VM restart — disturbs running containers);
c) authorized volume prune of unreferenced `act-*` volumes (2.914GB immediate,
   ~10GB if the two CI-court 1.5GB/0.7GB volumes are confirmed stale).

## Receipt

- Commands run with exits: builder prune (0), image prune (0), exited ps (0),
  busybox df (0), busybox rmi (0). No containers touched, no daemon restart.
