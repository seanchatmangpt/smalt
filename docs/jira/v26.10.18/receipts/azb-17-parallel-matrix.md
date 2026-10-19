# AZB-17 — parallel plane matrix (1x4 salvage probe)

- **Work order**: AZB-17 (parallel plane matrix)
- **Standing**: `PARTIAL_ALIVE` — 3/4 planes green; the integration-plane cell fails reproducibly, so the merged gate is REFUSED. NOT green; AZB-18 staged leg stays blocked on the integration cell.
- **Context**: solo
- **Subject SHA**: `21060325ec35e3940be5b9df023ecc7d00dd78b0` (fresh run) / prior artifacts at `dda0bf5c…` (21:58) and `0009df32…` (22:07, == HEAD at run time)
- **Image digests**: `sha256:7edd4489…` (fresh run), `sha256:fc874209…` (prior artifacts — different image identity than the fresh run)
- **Harness**: `docker/burn/parallel-matrix.sh` (per-replica netns isolation, per-plane chaos, tenant canary, `validate_burn.py --gate`)

## Prior artifacts (salvage review)

- `docs/jira/v26.10.18/burn/parallel-matrix-1x4-1792385907.jsonl` — 21:58, subject `dda0bf5c`. 4 cells: data CLEAN; control/integration/identity chaos `UNHANDLED_EXIT` (rc=1, broken_term `mu_unlawful`). Not green.
- `docs/jira/v26.10.18/burn/parallel-matrix-1x4-1792386075.jsonl` — 22:07, subject `0009df32`. 4 cells: control 2/2 CLEAN, data 2/2 CLEAN, identity chaos CLEAN but probe `UNHANDLED_EXIT` ("release never opened :9443 within deadline"), integration chaos+probe `UNHANDLED_EXIT`. Not green.

Neither prior artifact is a green 1x4, so no receipt was fabricated from them; a fresh minimal-scale run was executed instead.

## Fresh 1x4 run (2026-10-19 05:30–05:32 UTC)

Command: `bash docker/burn/parallel-matrix.sh --replicas 1` (after `--emit-compose 1` regeneration of `docker/burn/compose.burn.yml`).

Gate file: `docs/jira/v26.10.18/burn/parallel-matrix-1x4-1792387831.jsonl`

Per-plane verdicts (probe stage):

| plane | probe | chaos scenario | chaos | isolation |
|---|---|---|---|---|
| control | CLEAN (`cross_tries=7 cross_reads=0`) | s3-wasm-seal | CLEAN | netns, cross_reads=0 |
| data | CLEAN (`cross_tries=7 cross_reads=0`) | s1-store-kill | CLEAN | netns, cross_reads=0 |
| integration | `UNHANDLED_EXIT` (`flood_conns=2073 atom_log_lines=2073 chaos_rc=1`) | s4-amqp-capacity | `UNHANDLED_EXIT` rc=1 | netns, cross_reads=0 |
| identity | CLEAN (`canary=ok`) | s5-identity-sts | CLEAN | netns, cross_reads=0 |

Gate verdict: **REFUSED** —
`[VALIDATE-BURN] DIRTY_ROW container=smalt-burn-integration-1 cycle=0 stage=chaos verdict=UNHANDLED_EXIT broken_term=mu_unlawful`
(same for stage=probe). Canary cross-reads = 0 across all cells. Preflight held (0 published host ports). Exit 1.

## Reproducible defect: integration plane / s4-amqp-capacity

The integration cell fails identically in all three runs (both image digests), so this is a real integration-plane defect, not environment noise: the `s4-amqp-capacity` scenario (fill `chaos-capacity` queue to 4096 via `Smalt.Amqp.QueueStore.enqueue/2`; #4097 must return `{:error, :capacity}` typed; `queue_info.capacity == 4096`) exits rc=1, and the follow-on probe exits with `flood_conns=2073 atom_log_lines=2073 chaos_rc=1`. Candidate diagnosis was cut short — see blocker.

## Blocker: docker-disk-exhausted

The follow-up one-off reproduction container failed to even start:

```
docker: Error response from daemon: apply layer error for "": failed to extract layer
sha256:3e87f80a…: write .../libexplorer-v0.13.0-nif-2.15-aarch64-unknown-linux-musl.so:
no space left on device
```

Docker Desktop disk state at failure (`docker system df`):

```
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          4         2         16.47GB   14.99GB (91%)
Containers      5         5         3.961MB   0B (0%)
Local Volumes   23        2         22.71GB   2.914GB (12%)
Build Cache     23        23        7.187GB   0B
```

Host: `df -h /System/Volumes/Data` → 859Gi used, **40Gi avail, 96% capacity** (926Gi volume).
`Docker.raw` is capped at 32G (`~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw`).

Safe reclamation attempted per lane authority: `docker builder prune -f` → **0B reclaimed** (all build cache ACTIVE), `docker image prune -f` → **0B** (no dangling images). The 14.99GB "reclaimable" images and 2.9GB unused volumes would require removing tagged images/volumes owned by other lanes — NOT pruned. Growing Docker.raw beyond 32G is a Docker Desktop settings change, outside lane authority.

**Verdict for step 4 of the probe: `BLOCKED[docker-disk-exhausted]`.**

## Replay

```
bash docker/burn/parallel-matrix.sh --emit-compose 1
bash docker/burn/parallel-matrix.sh --replicas 1     # exit 1, gate REFUSED
python3 scripts/validate_burn.py --gate docs/jira/v26.10.18/burn/parallel-matrix-1x4-1792387831.jsonl
docker system df
```

## Falsifier / close condition

AZB-17 closes green when a full run ends `VERDICT: CLEAN` with `validate_burn.py --gate` accepting the merged file. The single blocking cell is `smalt-burn-integration-1` (s4-amqp-capacity + probe). Fix must land in the integration plane (`Smalt.Amqp.QueueStore` capacity path / AMQP link-close mapping), then rerun `--replicas 1` before the full 8x4.

## Receipt standing derivation

Derived from the data, not asserted: 3/4 plane cells CLEAN with zero cross-tenant reads proves the per-replica netns isolation and canary laws on those cells; the refused gate file (DIRTY_ROW) and rc=1 verdict are the authority for PARTIAL_ALIVE, not green.
