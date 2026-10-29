# BK-PLATFORM-ROUTE — platform pseudo-resource metric face routed

**Standing**: ALIVE · **Context**: solo · **Date**: 2026-10-22 · **Subject**: `/Users/sac/smalt` working tree @ lane build root `_build-bkplat` (coordinator owns git; commit by lane with explicit paths)

**Disclosure (checkpoint absorption, BK-DLQ3 pattern)**: coordinator checkpoint
`67ffe6ec` absorbed the in-flight lib fix (`lib/smalt/arm_gateway/router.ex` route +
handler) and the initial court test mid-lane; this lane's commit `d8f09ebb` carries the
receipt, the post-checkpoint court corrections (L2 envelope-name shape, L4 future-pin
api-version), and the census registration. Working tree byte-identical to HEAD on all
lane-owned files.

## What closed

BK-MON5's typed carry-forward **PLATFORM-FACE-UNROUTED** (bkmon5-metrics-verify.md,
Probe 3): the monitor accumulator keys non-ARM traffic and platform events
(`EgressRefused`, `SentinelDropped`/`SentinelKept`) under the 2-segment id
`providers/Smalt.Monitor/platform` (no name segment), but the metrics route family
required 3 segments (`providers/:ns/:type/:name`) — wire GETs answered **404
RouteNotFound** while in-process `series/5` on the platform key was coherent.

**Disposition: routed, not typed UNSUPPORTED.** Real Azure Monitor exposes platform
metric faces (Microsoft.Monitor platform shape) — the face is real, so the honest close
is the route.

## Change (lib/smalt/arm_gateway/router.ex — the lane's owned metrics region)

- Literal platform metric route, declared with the metrics family (before the azapi
  globs, and segment-count-distinct from the generic 2-segment provider list route at
  router.ex:6831):
  `GET /subscriptions/_smalt_monitor/resourceGroups/_smalt_monitor/providers/Smalt.Monitor/platform/providers/microsoft.insights/metrics`
- `handle_metrics_platform/1`: same serve path as the per-resource fallback —
  `Smalt.Monitor.Metrics.series/5` on `platform_resource()` (exact downcased-equality
  join, the bkmon3r law), else the real-Azure empty envelope. No Store probe: the
  platform pseudo-resource is never in `:smalt_resources`, so the handler goes straight
  to the accumulator. api-version gates (`check_api_version/2` +
  `check_metrics_api_version/1`, monotonic per the KD-78 shape) ride the same `with`.

## Court (Chicago, no mocks) — test/internal/bkplat_platform_route_court_test.exs

Real `:telemetry` events into the real attached handler, real tuple-keyed ETS, real
HTTP/1.1 over loopback against the self-booted router (`mix test` ephemeral-port boot).

```
$ MIX_BUILD_ROOT=_build-bkplat mix test test/internal/bkplat_platform_route_court_test.exs \
    test/internal/bkmon3r_deadjoin_court_test.exs test/internal/plane_blast_radius_test.exs \
    test/integration/ja10_transparency_court_test.exs
Finished in 2.8 seconds (0.00s async, 2.8s sync)

Result: 19 passed
```

- **L1** platform face routed: 3 seeded platform Requests (real bandit event on a
  non-ARM path) → GET face → 200, totals >= 3.0 from the accumulator (pre-fix: 404
  RouteNotFound — the "before" witness is BK-MON5's live-wire observation, cited; no
  swap-probe performed, coordinator owns git).
- **L2** BK-MON6 integrity: EgressRefused (real `[:smalt, :egress, :refused]` event) and
  Requests independently addressable, each envelope echoes its OWN metric name (no
  cross-metric join); RequestDuration totals = seeded 2 x 13 ms exactly.
- **L3** metric with no platform rows → 200 empty `value[]` envelope.
- **L4** api-version gate: 2099-01-01 → 400 (monotonic admission, KD-78 shape — refusal
  pin is a FUTURE version; a 1999 pin was corrected mid-court: it 200s by law).

Regression: the bkmon3r dead-join court (4 legs), plane_blast_radius, ja10 transparency
all green in the same run (19 passed total).

## Census registration (test/internal/internal_tier_census_test.exs)

File registered `:wire`; typed exemptions `[:client_token, :arm_literal]` (raw Erlang
HTTP client harness + the literal platform metric-face path); observables rows added for
the court module and the pseudo-provider namespace string `Smalt.Monitor` (a wire id, not
a module). Court legs re-ran green post-registration (census-affected legs: none; full
court re-run embedded above).

## Pre-existing / other-lane state (disclosed, NOT touched by this lane)

`test/internal/internal_tier_census_test.exs` currently fails 3/6 census tests on OTHER
lanes' unregistered in-flight files: `event_grid_dlq_worm_spill_court_test.exs`,
`kafka_downcv_court_test.exs`, `sts_key_cluster_purity_test.exs`, `hang_reap.exs`
(also one unaudited `Process.sleep(20)` in hang_reap.exs). None of these name this
lane's file; registration is the census owner's/registrar's surface.

## Verdict

Platform metric face routed end-to-end (telemetry → accumulator ETS → wire 200).
**ALIVE**. Carry-forward for the shared substrate: it needs the next recycle to compile
this route in (same typed note as BK-MON5's stale-beam finding).
