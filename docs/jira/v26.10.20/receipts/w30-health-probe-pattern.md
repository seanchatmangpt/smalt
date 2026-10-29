# W30-I — Cosmos vNext health-probe pattern witness (REPORT ONLY)

**Standing:** **ALIVE (pattern witnessed)** — real emulator booted, three-way probe
surface executed, bounded no-sleep poll, zero errors.

Context: solo

Date: 2026-10-21
Subject: Azure Cosmos DB emulator `vnext-preview`
(`mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview`,
digest `sha256:db53613dae19d0a3d5ad50688d14aa6e957af082dafea56b52e1bd3a6b3f1406`),
Docker available — REAL witness path taken. Container removed after witness.
Probe script: `/tmp/w30i_probe.sh`.

## Executed

```
docker run -d --name smalt-w30i-cosmos -p 18080:8080 \
  -e PROTOCOL=https mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
bash /tmp/w30i_probe.sh
docker rm -f smalt-w30i-cosmos
```

Bounded readiness poll (deadline 300s, poll-on-observable, no fixed
coordination sleep): `/ready` reached HTTP 200 within the window. Probe outputs:

```
== /ready final HTTP 200 after bounded poll (deadline 300s) ==
GET /alive -> HTTP 200
GET /ready -> HTTP 200
GET /status -> HTTP 200
GET /nonexistent -> HTTP 404
```

Common 200 body (identical across all three routes):

```json
{
  "alive": true,
  "checks": {
    "explorer": "healthy",
    "gateway": "healthy",
    "postgres": "healthy"
  },
  "overall": true,
  "protocol": "https",
  "ready": true,
  "status": "healthy",
  "timestamp": "2026-10-21T16:38:01.848356508+00:00",
  "version": "EN20261019"
}
```

## What smalt healthz already covers

`/Users/sac/smalt/lib/smalt/health_plug.ex` + `/Users/sac/smalt/lib/smalt/health.ex`
(v26.10.19 adaptive-probe phase):

- **Liveness**: `GET /healthz/live` — constant 200 `%{status: "alive"}`,
  never fails on load (mirrors `/alive`; `Smalt.Health.liveness/0` = `:alive`).
- **Readiness**: `GET /healthz` — 200 ready / 503 degraded, verdict driven by
  STRUCTURAL failures only (Store process down, StoreTables tables missing,
  ETS/process memory over high-water); scheduler load and cluster state are
  reported as metrics, never fatal (adaptive-probe law). This is semantically
  STRONGER than vNext's readiness: smalt degrades on a per-check basis, vNext
  collapses everything into one boolean `overall`.
- **No-sleep native**: probes are synchronous state reads — no polling inside
  the substrate; clients poll with bounded deadlines (this lane's witness
  pattern). No `Process.sleep` anywhere in the probe path (the one 100 ms
  scheduler sample in `Smalt.Health` is annotated `# SLEEP-CLASS: SCHEDULING`,
  a measurement interval, not coordination).
- CORS preflight handling on the health face (`204` + allow-methods) — richer
  than vNext's bare JSON.

## What the vNext probes add

1. **Three-way route split** `/alive` | `/ready` | `/status` as separate
   canonical paths (smalt uses `/healthz` + `/healthz/live`). Cosmetic mapping
   differs; semantic pair (liveness vs readiness) is the same.
2. **`/status` as an always-safe introspection route** — returns the full
   check map with 200 even when not ready, i.e. status is a REPORT route,
   not a verdict route. smalt folds this into `/healthz` (503 carries the
   same body); a dedicated always-200 `/healthz/status` would let load-
   balancer health checks and human operators share one URL without the LB
   killing degraded-but-live instances.
3. **Per-component named checks in the body** (`explorer`/`gateway`/`postgres`
   -> healthy) — smalt's `checks` map already does this
   (`scheduler`/`store`/`memory`/`cluster`), so parity, no gap.
4. **Version + timestamp in the probe body** (`version: "EN20261019"`,
   `timestamp`) — smalt's body has neither; a release-stamped health body
   makes fleet-skew diagnosis (which node runs which build) a curl, not a
   login.
5. **Single flat body for all three routes** — one serializer, no per-route
   drift. smalt already shares `Smalt.Health.to_json_map/1`; parity.

## Adoption recommendation (REPORT ONLY, no lib edit)

- **Adopt (low cost, real value)**: add `version` + `timestamp` fields to the
  health JSON in `Smalt.Health.to_json_map/1` — fleet build-skew becomes
  curl-visible. Candidate refinement, one function, test-fenced.
- **Optional**: alias `/healthz/status` -> always-200 report body (status vs
  verdict separation), matching vNext operator ergonomics.
- **Do NOT adopt**: the boolean `overall` collapse — smalt's structural vs
  load-metric distinction (adaptive-probe law, v26.10.19) is strictly stronger
  than vNext's verdict model.
- Route renames are unnecessary: the liveness/readiness pair is already
  congruent with `/alive`/`/ready`; the split is naming only.

## Falsifier status

Witness executed against the real pinned image; no simulated collaborator.
Not falsified: `/ready` -> 200 within bounded window on a cold container boot,
`/alive` and `/status` -> 200, unknown route -> 404. Remaining UNKNOWN: vNext
degraded-state body shape (no unhealthy component was inducible without
container mutation; out of scope for a report-only lane).

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3): replay ATTEMPTED, emulator would not boot

Replay attempted for real (pinned digest image present locally):
`docker run -d --name smalt-w30i-cosmos -p 18080:8080 -e PROTOCOL=https
mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview`, then a
bounded readiness poll. Two attempts:

```
attempt 1: python bounded poll, deadline 300s -> TIMEOUT last=None ; poll_exit=1
attempt 2: curl bounded poll, 600s window      -> final=000 after 600s ; GET /alive /ready /status -> 000
container removed after each attempt (docker rm -f, exit=0)
```

The pinned vnext-preview container never opened a readable HTTPS endpoint on
18080 within either window on this (non-quiesced, concurrently loaded)
machine — 2026-10-21's clean boot is not reproducing today. Typed:
SUSPECT-PERMANENT-with-owner → **substrate-op** class on a quiesced Docker
machine (original evidence stands as-of 2026-10-21).
