# T30-F1/F2 — EhThrottle wiring + RouteNotReady Retry-After hint

**Standing: ALIVE** (both audit findings closed at wire level)
Date: 2026-10-21
Closes F1/F2 of `docs/jira/v26.10.20/receipts/retry-after-audit.md` (T30RA, PARTIAL_ALIVE).

## F1 — EhThrottle wired into the EH publish path

Files:
- `lib/smalt/messaging/event_hubs.ex` — `send_event/3` now gates every publish
  through `Smalt.Messaging.EhThrottle.admit/2` (batches counted as N events
  via `batch_inner_messages/1`). Returns `{:error, {:throttled, face}}` when
  over quota. Default-OFF by construction: with no quota set, `admit/2`
  returns `{:ok, :admitted}` without touching state — witnessed behavior is
  byte-identical, and the eh tier (34 tests) confirms no trip.
- `lib/smalt/messaging/amqp/connection.ex` — the `:eventhubs` transfer arm
  matches the throttled return and settles the delivery REJECTED with
  `amqp:resource-limit-exceeded`, the retry hint in the error description
  (`EhThrottle.amqp_refusal/1` mapping, per the module's documented
  server-busy class) and `info: %{retry-after: s}`. Link stays alive.
- Typed choice disclosed: default quota stays OFF. A hard-coded
  events/second default would trip soak/stress populations. Operators opt in
  via `config :smalt, :eh_ingress_quota, {limit, window_ms}` (applied through
  `set_quota/3` lazily in `eh_admit_publish/2`), or per-hub via
  `EhThrottle.set_quota/3` / the hub-record `"quota"` field (existing).

## F2 — RouteNotReady carries the hint

`lib/smalt/egress_router.ex` `route_not_ready/1` now emits
`retry-after: 1` (same hint as the ARM 429/503 faces) alongside the existing
x-ms-request-id / x-ms-version header discipline. Real Azure Blob/Queue 503s
carry Retry-After; azure-core honors it ahead of exponential backoff.

## Tests (Chicago, real collaborators — real throttle ETS, real send_event storage, real router conn)

New: `test/internal/eh_throttle_wiring_test.exs` — 6 tests, 0 failures:

```
Finished in 0.1 seconds (0.00s async, 0.1s sync)
6 tests, 0 failures
```

- unit: admit under/over quota, typed face (limit/window_ms/retry_after_s)
- unit: `amqp_refusal/1` → `{:error, {:resource_limit_exceeded, desc}}`
- wire: `send_event/3` default-off admits (witnessed shape kept)
- wire: over-quota publish → `{:error, {:throttled, face}}`
- wire: `config :smalt, :eh_ingress_quota` opt-in throttles
- F2: 503 RouteNotReady carries `retry-after: 1`

EH tier (eh_arm, consumer groups, KD-115/128/134, geo-DR, ARM bridge, wiring):
```
34 tests, 0 failures
```

Router-related error batch (adaptive_health, health_probe_parity, blob_kd_fixes,
blob_xml_error, kd_conformance):
```
36 tests, 0 failures
```

## Pre-existing failures (not session-introduced, HEAD-baselined)

`test/integration/cross_surface_determinism_test.exs` CTQ-3 (2 failures,
FunctionClauseError in `format_of/1` on cosmos round state): verified
pre-existing by snapshotting my three edited files via `git show HEAD:...`
(no stash), running the test on the HEAD versions — `2 tests, 2 failures`
on the clean baseline too. Unrelated surface (cosmos determinism vs. EH
throttle / router 503 header).

## Diff stat (session files only)

```
 lib/smalt/egress_router.ex              | (route_not_ready +retry-after: 1)
 lib/smalt/messaging/amqp/connection.ex  | (EH transfer arm throttle match + alias)
 lib/smalt/messaging/event_hubs.ex       | (send_event gate + eh_admit_publish/hub_of)
 test/internal/eh_throttle_wiring_test.exs | (new, 6 tests)
```

## Disclosures

- Compile-freeze unblock attempt on another lane's in-flight
  `lib/smalt/powl2/compiler.ex` (untracked, multiple syntax errors):
  my scripted fix did NOT apply (anchor mismatch — the lane repaired the
  stray `@doc false` themselves ~1 min later; compile went green). No edit of
  that file landed from this lane; final tree state is the powl2 lane's own.
- Shared `atom_bridge.ex` shows concurrent-lane modifications in diff stat —
  not authored by this lane.

## Falsifier status

- F1 falsifier: over-quota publish still settles `:accepted` → REFUTED
  (wired test proves REJECTED + typed condition).
- F2 falsifier: 503 without the header → REFUTED (header asserted).
