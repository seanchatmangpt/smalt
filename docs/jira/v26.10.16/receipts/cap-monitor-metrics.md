# Receipt: cap-monitor-metrics — Azure Monitor metrics capability (Smalt.Metrics + ARM wire surface)

Standing: PARTIAL_ALIVE
Date: 2026-10-16
Window: v26.10.16
Lane: DoD (docs; no build/test commands run this lane)

## Scope landed

- `lib/smalt/metrics.ex` — `Smalt.Metrics`: ETS-backed metric points
  (`Store` table), monotonic api-version admission, dense bucketed
  timeseries query, timespan/interval parsing.
- `lib/smalt/arm_gateway/router.ex` — metrics wire surface:
  `GET/POST .../providers/microsoft.insights/metrics` (bucketed timeseries
  query; custom-metrics-shape emit), lifecycle `Requests` emission, azapi
  emit unknown-resource 404.

## Capability points

1. **ETS point store** (`lib/smalt/metrics.ex`): each `emit/5` writes one
   `Store` row keyed
   `"<downcased resource_id>|<metric>|<ts_ms>|<monotonic-unique>"` with
   `%{"value" => float, "unit" => binary, "ts" => ts_ms}`. Case-insensitive
   resource-id lookup; unique-integer suffix disambiguates same-millisecond
   points.
2. **Monotonic api-version admission** (`version_admitted?/1`): well-formed
   `YYYY-MM-DD[-suffix]` compared against the family latest
   `2024-02-01` (`@latest_api_version`, `latest_api_version/0`);
   older-or-equal admitted, newer/malformed/missing refused with
   `InvalidApiVersionParameter` 400 naming the latest supported version
   (KD-78 monotonic family pattern; router lines ~920-935).
3. **Dense bucketed timeseries** (`query/5`): ARM-shaped single-metric
   series over `[start_ms, end_ms]` bucketed at `interval_ms`; every
   interval step present (zero-filled), empty buckets carry only
   `timeStamp`, non-empty carry `{timeStamp, total, count, average}`.
   `parse_timespan/1` and `parse_interval/1` (default 60s interval) match
   the ARM `timespan`/`interval` query params.
4. **Wire routes declared BEFORE the azapi POST glob** (router ~3334-3340
   declared before ~3342): the azapi POST glob otherwise shadows the
   metrics emit route. Shadowing was witnessed during the wave and fixed by
   route-order; the comment block at router 3327-3333 pins the ordering
   constraint. The azapi fallback itself answers 404
   `No azapi action at path '<path>'` for unmatched paths.
5. **Lifecycle `Requests` emission**: `handle_resource_put` emits
   `Smalt.Metrics.emit(res_id, "Requests", 1)` on successful resource PUT
   (router ~777), so queried series have data without custom emits.
   `default_metric/0` = `"Requests"`.
6. **azapi emit unknown-resource 404**: `handle_metrics_emit` looks the
   resource up in `Store` (`:smalt_resources`, downcased id); a miss
   returns ARM-typed 404 `ResourceNotFound` rather than emitting into a
   dangling series (router ~876-914). Note: GET query for a nonexistent
   resource intentionally 200s with no series (real Azure Monitor
   semantics, comment at router ~843-845).

## Test evidence (cited, not re-run per lane contract)

`test/smalt_metrics_test.exs` — **9 tests, 0 failures** as last run by the
implementing lane. Coverage: api-version admission (older/equal/newer/
malformed), emit + dense bucketed query, timespan/interval parsing,
Requests lifecycle point.

## Route-order shadowing fix (witnessed)

Metrics routes were initially shadowed by the azapi POST glob (`.../lock`,
`.../setLegalHold` at any depth); the metrics emit POST never fired. Fixed
by declaring the nested-provider metrics routes before the glob; pinned by
comment at `lib/smalt/arm_gateway/router.ex` lines 3327-3333.

## Cross-lane disclosure (compile-freeze SLA unblock)

This lane disclosed a minimal unblock edit in
`lib/smalt/arm_gateway/router.ex` `handle_resource_put`: a stale duplicate
`cond` clause (left in-flight by the policy lane) was removed to restore
shared compile. Per same-checkout-fanout addition 6, the disclosure is
named in BOTH receipts: this one and the policy lane's receipt for the same
window.

## Replay

```
grep -n "microsoft.insights/metrics" lib/smalt/arm_gateway/router.ex   # route order vs azapi glob
grep -n "version_admitted?\|@latest_api_version" lib/smalt/metrics.ex
mix test test/smalt_metrics_test.exs    # expect: 9 tests, 0 failures
```

## Falsifier (what would close PARTIAL_ALIVE → ALIVE)

- `mix test test/smalt_metrics_test.exs` re-run this window returning
  non-zero, or
- a route census showing any `providers/microsoft.insights/metrics` route
  declared after the azapi POST glob.
