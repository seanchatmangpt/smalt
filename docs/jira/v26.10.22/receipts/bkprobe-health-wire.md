# BK-PROBE — health probes wired to the real kernel self-report (BK-ARM1 F-1 closed)

**Standing:** ALIVE
**Context:** solo
**Date:** 2026-10-22
**Lane:** BK-PROBE. Repo /Users/sac/smalt (canonical checkout, MIX_BUILD_ROOT=_build-bkprobe).

## What landed

| File | Change |
|---|---|
| `lib/smalt/arm_gateway/router.ex` | Two new routes declared before the flat ATOM aliases/catch-alls: `GET /.well-known/health/ready` → `Smalt.Health.readiness/0` rendered via `Health.http_status/1` (200 ready / 503 degraded) + `Health.to_json_map/1`; `GET /.well-known/health/live` → `liveness/0` (200 alive). Paths sit in the `/.well-known/` bearer-exempt namespace (Smalt.Auth.Bearer `@exempt_prefixes`) — kubelet probes are tokenless bootstrap-class requests. |
| `k8s/smalt-backend.yaml` | readinessProbe httpGet → `/.well-known/health/ready`, livenessProbe httpGet → `/.well-known/health/live` (port `arm-mgmt`). Was: both probes on `/metadata/endpoints`, a static always-200 metadata handler — kubelet could only detect a dead listener, never a degraded BEAM (BK-ARM1 F-1). |
| `k8s/smalt-backend.gen.yaml` | Same probe paths, carried by re-render. Current on-disk render is BK-MKT1's full smalt-k8s-pack StatefulSet render; the probe blocks render from the ttl facts (below). |
| `priv/smalt-k8s.ttl` | backend container probe blocks → `/.well-known/health/ready|live` (cross-lane minimal edit, disclosed: BK-MKT1 rewrote this file mid-lane; my probe blocks are inside their landed version — committed by their receipt commit 01ecff72, verified on disk post-landing). |
| `test/integration/bkprobe_health_wire_test.exs` | Court: 4 legs. |

## Court (embedded, real run)

```
$ MIX_BUILD_ROOT=_build-bkprobe mix test test/integration/bkprobe_health_wire_test.exs
Finished in 0.03 seconds (0.00s async, 0.04s sync)
Result: 4 passed

$ scripts/fast_test.sh test/integration/bkprobe_health_wire_test.exs   # isolated private build root _build-ft-db22e6b6
Result: 4 passed   [09:47:46] wall: 82s
```

Legs, Chicago-style (real router, real Store, real Health — no mocks):

1. **Healthy → 200 ready**: tokenless GET /.well-known/health/ready through the real
   router returns 200 with `"status" => "ready"` and `checks.store == "ok"`,
   `checks.memory == "ok"` (real ETS tables, real memory readings).
2. **Degraded → 503 (the kubelet-as-supervisor contract closes)**: a REAL structural
   degradation forced via the module's documented bound seam —
   `Application.put_env(:smalt, Smalt.Health, ets_memory_high_water_bytes: 0)` makes the
   actual `:erlang.memory(:ets)` reading over high-water → `readiness/0` returns
   `{:degraded, _}` → route answers **503** with
   `checks.memory.error =~ "ets_memory_over_high_water"`. Before this fix a degraded pod
   answered 200 forever on /metadata/endpoints.
3. **Liveness → 200 alive** per `Health.liveness/0` (process/scheduler-only face;
   never fails on load by design).
4. **Bearer-exempt in :enforce mode**: tokenless requests to both faces with
   `auth_mode: :enforce` are NOT 401 (200) — the probe path works for real kubelet.

`mix format` clean on both edited files.

## Cross-lane disclosures (compile-freeze disclosure law)

- **lib/smalt/cluster.ex mid-lane compile break** (`schedule_next/1` undefined):
  another lane's in-flight refactor; NOT touched by this lane; settled by its owner
  before final compile (green, exit 0, dep warnings only).
- **priv/smalt-k8s.ttl clobber + re-render**: BK-MKT1 rewrote the ttl (smalt-k8s-pack)
  mid-lane, briefly reverting my probe blocks; I re-applied the health paths to their
  landed version; their successful re-render (after ggen.lock re-lock, FM-PACK-008
  observed once on the stale lock) carried the health paths into
  k8s/smalt-backend.gen.yaml (0 occurrences of /metadata/endpoints remain on disk;
  lines 219/227). Both files were committed by BK-MKT1's receipt commit 01ecff72 while
  this lane ran — the working-tree deltas this commit adds are the post-format router
  formatting and the `checks.memory.error` assertion fix (the serialized memory check is
  a JSON object, not a string).
- **ggen.lock**: re-locked by BK-MKT1, not this lane.

## Armstrong check

Smalt.Health is the kernel's self-report (read-only ETS/memory/process inspection);
the router route is a thin typed rendering (200/503, no rescue, no swallow); kubelet is
the outermost supervisor now acting on a truthful face. The boundary is honest: BEAM
gives up ⇒ container exits ⇒ kubelet restarts (leg 1); BEAM degraded ⇒ ready answers
503 ⇒ kubelet pulls the pod from Service rotation and restarts per failureThreshold 5 /
periodSeconds 3 (leg 2). Both legs of "let it crash crosses the container line" now fire.

## Residuals

- `test-budget`: 4 new unbudgeted tests — seed via `just test-budget-seed` at wave
  integration (coordinator).
- Liveness is constant `:alive` by the module's own adaptive-probe law (never fails on
  load); honest per its documented contract, not a defect.
- BK-MKT1's typed successor (retire hand-written smalt-backend.yaml to
  validation-reference) is coordinator-owned; both surfaces now agree on the health
  paths regardless of which stays canonical.
