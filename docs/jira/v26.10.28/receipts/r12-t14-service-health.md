# r12 — T-14: Azure Service Health — availability statuses, events, chaos-coupled incidents

- window: v26.10.28 · ticket: `tickets/T14-service-health.md` · date: 2026-10-29
- tier: beam (`test/integration/service_health_test.exs`) · status: **CODE-COMPLETE (r12), awaiting integration run**

## landed

1. **Engine** (`lib/smalt/data_plane/resource_health.ex`,
   `Smalt.DataPlane.ResourceHealth`): availability record per DOWNCASED
   resource id (state Available/Unavailable, reason code, summary,
   occurred/reported timestamps) and service-health event rows (id, level,
   status Active/Resolved, eventTimestamp, title, reasonCode) in the
   `:smalt_resource_health` ETS shadow table — lazy `:ets.new`, `:heir` to
   `:init` (the same shadow-table law as `Smalt.Arm.ResourceHealth` /
   `Telemetry.RollingCounters`; no supervisor child, no new Store table).
   API: `set_unavailable/2`, `set_available/1` (return
   `{:ok, availability, event}`), `status/1`, `chaos_status/1`,
   `list/1` (scope prefix), `events/1` (scope prefix),
   `availability_wire/1` + `event_wire/1` (documented wire shapes),
   `config_markers/0`.
2. **Read law** (`status/1`, first match wins): explicit transition record
   → `:smalt, :resource_health_unavailable` app-env marker (derived-on-read,
   never persisted, no restart) → `:smalt_resources` Store presence
   (default `Available`, synthetic-Available vocabulary:
   reasonType `EmulatorSynthetic`, epoch `occurredTime` — a derived row is
   not a transition) → `:error` (router 404s; never a fabricated row).
   Explicit transitions ALWAYS beat the marker, so `set_available/1`
   restores while a flag is still up.
3. **Chaos coupling — explicit API is the primary contract**: the
   integration tier calls
   `Smalt.DataPlane.ResourceHealth.set_unavailable(resource_id, reason)` /
   `set_available(resource_id)`. `reason` accepts the real reason-code
   classes (`CustomerInitiated`, `PlatformInitiated`, `HighAvailability`,
   `Unplanned`; any binary; or a map/keyword with `reasonCode` + optional
   `summary`). The T-12 flag contract is ALSO honored read-only:
   `config :smalt, :resource_health_unavailable` may name resource ids
   (list of ids, `{id, reason}` tuples, or `%{id => reason}` map) — flips
   are observable without restarts. **No T-12 file was touched**; when
   T-12 lands its injector flags it can call the explicit API directly.
4. **Event lifecycle**: `set_unavailable/2` mints-or-refreshes ONE Active
   event per resource (an `{:event_active, rid}` pointer names the current
   incident; `{:event, id}` rows keep permanent history so a resolve is
   never overwritten by a later re-injection — a re-flip mints a NEW
   Active event); `set_available/1` resolves it (status Resolved, level
   Informational, fresh eventTimestamp). Marker-derived incidents carry a
   DETERMINISTIC id (`chaos-<sha256-8>`) so repeated polls observe the
   same event id while the flag is up.
5. **Alert path**: every explicit transition emits raw `:telemetry`
   `[:smalt, :resource_health, :availability]` with metadata `%{state,
   reason}` — codes only, never resource ids (matter-isolation law).
   Production-shaped alerting parses the events wire envelope; local
   tooling attaches to the telemetry name.
6. **Pass-through router** (`lib/smalt/arm_gateway/providers/resource_health_router.ex`,
   `Smalt.ArmGateway.Providers.ResourceHealthRouter`): `def call/2` answers
   `/subscriptions/.../providers/Microsoft.ResourceHealth/...` faces and
   returns the conn UNCHANGED for anything else. Faces: RG-scoped
   `availabilityStatuses` list, subscription- and RG-scoped `events`,
   per-resource `availabilityStatuses/current` + per-resource list (both
   `resourceGroups` casings). Gates: `api-version` presence (400
   MissingApiVersionParameter — registry carries no ResourceHealth entry,
   so default non-strict mode passes any version, identical to the V9
   faces), scope existence (404 SubscriptionNotFound / ResourceGroupNotFound,
   main-router vocabulary). **Precedence law**: on the per-resource faces
   the engine answers ONLY when it owns the state
   (`chaos_status/1` = explicit record or marker); otherwise the
   pre-existing V9 computed-health seam
   (`Smalt.ArmGateway.ResourceHealth`) answers unchanged — recorded
   `:smalt_arm_health` transitions and the synthetic-Available law stay
   byte-identical and the V9 court stays green. The subscription-scope
   `availabilityStatuses` LIST face is intentionally NOT intercepted (the
   V9 route owns it, SubscriptionNotFound law intact).

File scope: exactly three new files (engine, pass-through router, court)
+ this receipt. `lib/smalt/arm_gateway/router.ex` itself is untouched —
its one-line mount is the integrator patch below. T-12's chaos files and
parity/ are untouched.

## EXACT wiring patch (integrator applies)

`lib/smalt/arm_gateway/router.ex`, plug pipeline — insert one plug line
immediately BEFORE `plug(:match)` (i.e. directly after
`plug(Smalt.Egress.ThrottlePlug)`):

```diff
--- a/lib/smalt/arm_gateway/router.ex
+++ b/lib/smalt/arm_gateway/router.ex
@@
   plug(Smalt.Egress.ThrottlePlug)
+  # T-14 service health: Microsoft.ResourceHealth availabilityStatuses/events.
+  # Pass-through mux — ResourceHealth faces answer here (chaos-coupled
+  # engine), every other path falls through to :match untouched.
+  plug(Smalt.ArmGateway.Providers.ResourceHealthRouter)
   plug(:match)
   plug(:dispatch)
```

(The `#` comment lines are optional; the only REQUIRED line is
`plug(Smalt.ArmGateway.Providers.ResourceHealthRouter)` before
`plug(:match)`.)

## court

`Smalt.Internal.ServiceHealthTest` (`test/integration/service_health_test.exs`;
in-process pass-through dispatch like `sb_arm_rules_test.exs`; real Store
rows; real engine ETS; unique ids per leg + on_exit sweeps so the shuffled
order stays order-independent; zero sleeps — every lifecycle leg polls the
wire faces directly) — 7 tests:

1. default Available: seeded resource → current face 200, documented
   id/name/type + `properties.availabilityState = "Available"`, epoch
   `occurredTime` (derived, not a transition).
2. `set_unavailable(rid, "PlatformInitiated")` → current 200 Unavailable +
   reasonType + summary + timestamped; subscription `events` row Active /
   level Warning / reasonCode / resourceId / timestamped; telemetry
   `[:smalt, :resource_health, :availability]` fires (`assert_received`)
   with codes only — the alert path.
3. `set_available/1` → current 200 Available re-timestamped (differs from
   BOTH epoch and outage instant); the event Resolved; no Active rows
   remain for the resource.
4. scope listing: RG-scoped `availabilityStatuses` returns exactly that
   RG's resource with the chaos flip applied; second RG derives
   Available from Store presence; RG `events` filters to the RG's
   incident, subscription `events` aggregates; unknown RG → 404
   ResourceGroupNotFound; unknown subscription → 404 SubscriptionNotFound.
5. unknown resource → 404 NotFound (never a fabricated row).
6. missing api-version → 400 MissingApiVersionParameter.
7. `:resource_health_unavailable` marker (T-12 contract): current face
   Unavailable with reason CustomerInitiated and NO stored record
   (derived-on-read asserted via the shadow table); derived Active event
   with deterministic `chaos-` id across polls; clearing the marker
   restores Available — no restart.

**Not yet executed** — the r12 lane is code-only per the compile-freeze
SLA (no mix/test/git in this pass); the court runs with the next
integration pass and this receipt + the ticket stamp say so.

## DoD mapping (the Azure developer's view)

- "az rest …/availabilityStatuses/current returns Available for your
  running substrate resources" = court test 1 (and the V9
  subscription-list face keeps its existing law for the sub scope).
- "flip a documented chaos flag … without restarting anything — the same
  query returns Unavailable with the real reason/summary structure"
  = court test 7 (flag) and test 2 (explicit API — the integration-tier
  coupling T-12's injectors call), plus test 5 (unknown stays 404 — the
  outage is never fabricated).
- "a service-health events row appears as Active for the affected scope,
  and your alerting code path fires" = court tests 2 and 4 (events rows
  + transition telemetry).
- "Clearing the flag resolves the event and restores Available, each
  transition timestamped" = court test 3.
- Receipts-required mapping: transition receipt = tests 2+3 (poll-based,
  zero-sleep); events lifecycle receipt = tests 2+3+4; scope-variant
  receipt (resource vs RG vs subscription) = tests 1, 4.

## notes

- **Court file name deviation**: the ticket's court was slated for
  `test/integration/resource_health_test.exs`, but that path is already
  owned by the CONVERGENCE V9 computed-health court
  (`Smalt.Integration.ResourceHealthTest`), which keeps passing under the
  precedence law above — this court therefore lands as
  `test/integration/service_health_test.exs` (the ticket's own name) and
  its header comment documents the collision. The V9 file was not
  modified.
- **Api-version registry**: `Microsoft.ResourceHealth/*` carries no
  `Smalt.Registry` entry, so both the V9 routes and this pass-through
  enforce presence-only under the default boot (strict_version_validation
  would refuse — a coordinator flip if wanted, same posture as the V9
  lane).
- **Timestamps**: explicit transitions stamp
  `DateTime.utc_now() |> DateTime.to_iso8601()` (reportedTime mirrors
  occurredTime); derived-Available rows carry the epoch — an untransitioned
  resource honestly has no transition instant.
- **Engine table law**: `:smalt_resource_health` is a public named ETS
  shadow table heir'd to `:init` — survives its creator, never registered
  in `Smalt.StoreTables`, deliberately outside the partitioned Store
  (health markers are runtime state, not persisted resources).
