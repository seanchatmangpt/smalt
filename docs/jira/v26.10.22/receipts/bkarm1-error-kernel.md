# BK-ARM1 — Armstrong error-kernel audit across the k8s boundary

**Standing:** PARTIAL_ALIVE (audit complete, all four findings typed; no lib/ edit was this lane's to make — every defect is owned by a named surface, ticketed below)
**Context:** solo
**Date:** 2026-10-22
**Lane:** BK-ARM1. Read-only audit + receipt; zero lib/ or test/ edits.

## 1. Supervision tree map (BEAM side → kubelet)

```
kubelet (outermost supervisor; restartPolicy + probes)
  └─ container exit = BEAM halt ⇒ restarts pod            [k8s/smalt-backend.yaml]
       └─ Smalt.Supervisor (:one_for_one, application.ex:66)
            ├─ Smalt.Plane.{Data,Control,Integration,Identity}Supervisor   (AZB-09)
            ├─ Smalt.Apim, Smalt.Telemetry.RollingCounters, Smalt.Monitor.Metrics   [direct top-level children]
            ├─ MCP Bandit listener (or DeferredListeners + ListenerDeferral)
            ├─ virtual HW / journal sink / Smalt.Cluster (config-gated)
```

Crossing points observed:

- **Boot-config kernel, kernel-honest:** `SasVerifier.validate_boot_key!/0` (`:ok =` match,
  application.ex:44) and `bind_ip/0` (raises ArgumentError on bad SMALT_BIND_IP or
  config tuple, KD-54) refuse boot on bad config. Side-effect-free validation, fail-closed,
  no rescue anywhere on the path. Textbook Armstrong kernel.
- **Plane gating, kernel-honest:** unknown plane name refuses boot
  `{:invalid_plane, name}` (lib/smalt/planes.ex) — fail-closed, not tolerated.
- **k8s boundary — supervision-hole (ticketed, F-1):** the pod's **liveness AND readiness
  probes both point at `GET /metadata/endpoints`** (k8s/smalt-backend.yaml:183-196 and
  smalt-backend.gen.yaml:50-64) — a static ARM metadata JSON handler
  (arm_gateway/router.ex:3647) that returns 200 for as long as the Bandit listener is up.
  kubelet can therefore only detect a dead listener, never a degraded BEAM:
  `Smalt.Health.readiness/0` (store_integrity, memory high-water, cluster verdict) and
  `Smalt.Health.liveness/0` exist precisely for this and are wired to NOTHING. A pod whose
  Store integrity check fails is `:degraded` internally and indefinitely 200 externally.
  The "let it crash crosses the container line" contract is only half-honest: BEAM gives
  up ⇒ container exits ⇒ kubelet restarts — that leg is clean. The other leg (kubelet
  restarting a wedged-but-not-dead BEAM) cannot fire because the probe face lies.
- **lib/ catch-and-continue inventory (new swarm/topology faces clean):** the swarm court's
  `call_typed/4` (test/integration/swarm_court_test.exs:160) and peer court's erpc wraps
  are **typed boundary translation, not swallowing** — every failure maps to
  `{:error, {:node_down, node}} | {:error, {:erpc, reason}}`, unknown classes re-raise.
  `stop_peer/1` swallows but is teardown-only. The BK-SWARM consistency legs assert the
  NOT-replicated negative fail-closed instead of rescuing it — kernel-honest.
  In lib/, the only broad swallows are `Smalt.Store.journal_mutation/4`
  (lib/smalt/store.ex:293-312, rescues + catches and logs "journal append dropped") and
  `Smalt.Apim`'s rate-table `rescue ArgumentError` (lib/smalt/apim.ex:161).

## 2. Judgments on the three cited fixes

| fix | verdict | reasoning |
|---|---|---|
| BK-MON3R dead-join | **kernel-honest** | Fixed the wrong data (dead `\|` prefix join → exact equality) instead of catching the wrong data downstream. No rescue added; falsifier court flips on pre-fix tree. Pure error-kernel repair. |
| BK-PINIT stale-delete | **kernel-honest (not a defensive patch)** | Let-it-crash cannot heal this wound: the heir'd ETS table re-parents to `:init`, which never dies, so the crash residue SURVIVES the restart — supervisor healing re-enters the same `:already_exists` crash until intensity give-up kills the app. Deleting crash residue that outlives the crash in init is state repair, not symptom suppression. The bounded 15 s monitor wait is structural sync on a real observable (DOWN message), not a sleep, and skips the wait for `:init`-held tables (waiting would be a guaranteed 15 s stall — correct typed case split). |
| BK-ETSFIX intensity (test recycle via `Supervisor.terminate_child/restart_child`) | **defensive-smell (typed, test-side only)** | The edit moves the test's recycle out of the intensity counter instead of fixing the intensity config. The comment honestly discloses this ("does NOT count against restart intensity… production guarantee unchanged — no lib/ edit"), so it is a disclosed test-harness accommodation, not a lib/ lie. The underlying lib/ defect it papers over is F-2 below. |

## 3. Error-kernel inventory + Ja15 verdict

**Kernel (must never crash, minimal side effects):** `Smalt.Store` + its partition ETS
tables (the state), `Smalt.Config`/`SasVerifier`/`bind_ip` boot validation,
`Smalt.Planes` gating, `Smalt.Health` checks (read-only). These are side-effect-ful by
necessity (ETS writes ARE the kernel's state) — Armstrong's "side-effect-free" is honored
in the Armstrong sense: no message-send-and-hope, no external I/O on the hot path;
errors in the edges (routers, listeners, sweepers) crash and are supervised, the kernel
tables survive owner death via the `:init`-heir law (SPOF-B/A-4).

**Ja15 hostile-formatter race — kernel violation, fix was the correct repair.** The
court installed an always-crash formatter on the SHARED `:default` logger handler —
a test reaching outside its own surface and mutating the one process-wide logging
kernel face every async test depends on. That is precisely the "kernel must be correct"
violation: the kernel (shared logger config) was deliberately broken while other
processes depended on it. The fix (bkseal6-x2.md Defect 1) scopes the crash to the
court's own probe events and delegates the rest — kernel-honest repair, witnessed
154 → 4 failures. Verdict: **kernel-honest fix of a real kernel violation** (the
violation lived in test infra, and the fix repairs the infra, not the symptoms).

**Store journal drop (store.ex:293-312):** documented TTV-4 law ("best-effort journal,
never a crash of the data plane"), typed log line on every drop. Defensive BY DESIGN
and disclosed — but note the asymmetry: a WAL that silently continues (one warning)
after losing a durability frame is a real kernel-strength question if the journal is
ever relied on for recovery. Typed as F-3, owned by SJ-4/TTV surfaces.

**Apim rate table (apim.ex:148-170):** `rescue ArgumentError -> @rate_table` around
`:ets.new` — pre-PINIT-era race guard with NO stale-delete and NO ownership check: if a
stale heir-held table exists, this returns a name whose table is owned by `:init` with
possibly different options, and the module carries no convergence law. Same defect
class BK-PINIT fixed in sb_rules.ex. Owned by Apim surface. Typed as F-4.

## 4. Findings, ranked (each with Armstrong verdict + owner)

- **F-1 (supervision-hole) — k8s probes wired to a static endpoint.**
  k8s/smalt-backend.yaml:183-196 (+ .gen.yaml:50-64): liveness/readiness both GET
  `/metadata/endpoints`, which is 200 whenever the listener is up. `Smalt.Health` is
  dead code at the boundary. Fix: serve a typed health face (503 on `{:degraded, _}`
  from `Smalt.Health.readiness/0` for readiness; `Smalt.Health.liveness/0` for
  liveness) and point the probes at it; regen the .gen manifest. Owner: BK-K8SM /
  manifest owner.
- **F-2 (supervision-hole) — RollingCounters sits directly under Smalt.Supervisor with
  default intensity 1/5s.** bkseal6-x2.md Defect 2 witnessed 4 stop/restart cycles in
  5 s giving up the TOP-LEVEL supervisor → whole app dies (kubelet-restart class for a
  telemetry GenServer). BK-ETSFIX routed the test around it; the lib/ shape is
  unchanged. Fix (owning surface ETS-AUTO): child_spec with
  `max_restarts: 10, max_seconds: 5` (or nest under a dedicated infra supervisor) so a
  telemetry crash-loop cannot take the app. Owner: ETS-AUTO/BK-CENS3 (bkseal6 typed it
  NOT FIXED, same conclusion).
- **F-4 (defensive-smell) — Apim rate-table rescue without stale-delete.**
  apim.ex:148-170 is the pre-PINIT `:already_exists` class: rescue-continue, no
  ownership check, no convergence law. Fix: route through the BK-PINIT
  `ensure_table/2` law (delete `:init`-held stale, bounded monitor wait for live
  owners). Owner: Apim surface.
- **F-3 (defensive-by-design, typed) — Store journal drop-and-continue.**
  store.ex:293-312 is disclosed TTV-4 law, not a bug; the ticket question is whether a
  dropped WAL frame should ever be silent-`:ok` once journal recovery is load-bearing.
  Owner: SJ-4/TTV.

## Verification ladder

Read-only audit: application.ex, planes.ex, health.ex, store.ex, apim.ex, telemetry
recycle path (test/internal/ets_auto_court_test.exs), sb_rules.ex ensure_table,
swarm/peer courts, k8s/smalt-backend.yaml(+gen), arm_gateway/router.ex:3647, and
receipts bkseal6-x2 / bkmon3r-deadjoin-fix / bkpinit-stale-delete /
bkmon3-final-standing. No tests run, no edits made — nothing to verify beyond the
readings quoted with file:line above.
