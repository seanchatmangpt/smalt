# EXPL-11-R2 — Web PubSub F2/F3 repairs (events/service/socket)

Standing: **ALIVE** · Context: solo · Lane: EXPL11-R2 · Date: 2026-10-22

Lease: `lib/smalt/webpubsub/events.ex`, `lib/smalt/webpubsub/service.ex`
(extended: `lib/smalt/webpubsub/socket.ex` — F3 requires terminate-leave;
NOT `router.ex`, another lane's surface).

## What landed

**F2 (witness-buffer delivery truth)** — `events.ex`:

- Every witnessed event now carries `"delivered" => boolean` and
  `"delivery_status"` (`"pending"` initially; `"no_handler"` / `"delivered"` /
  `"refused:..."` terminal typings). `connect/3` still returns `:ok`
  (async module contract), but a dropped POST is never laundered: only a
  real 2xx from the loopback handler flips `delivered` to true.
- `deliver/2` (public for court) performs the real `:httpc` POST with 5 s
  timeouts, checks the status code, and reports the outcome back into the
  witness buffer via `{:delivery_result, id, delivered?, status}`.
- `service.ex` gained `handle_cast({:delivery_result, ...})` which updates
  the buffered event by `"id"` via `:queue.fold`. Both report shapes are
  accepted (4-tuple `{id, bool, status}` and 3-tuple
  `{id, {:delivered, code} | {:refused, r} | {:no_handler, nil}}`) — the
  events.ex surface was reconciled concurrently during the lane; accepting
  both shapes keeps service.ex stable against either.

**F3 (dead-pid membership leak)** — `service.ex` + `socket.ex`:

- `publish`/`members` handlers now prune dead pids from `state.groups`
  (the alive-filter pass already has the list in hand) and remove
  emptied groups/hubs. Falsifier closed: join + kill member → publish →
  dead pid gone from RAW `:sys.get_state`, not just read-filtered.
- `Socket` tracks joined groups in a new `:groups` field; `joinGroup`
  adds, `leaveGroup` removes, and `terminate/2` leaves every tracked
  group before emitting `disconnected`.

## Courts (test/internal/expl11r2_wps_service_events_court_test.exs)

Real processes, real loopback TCP, no mocks (Chicago). 3/3 PASS:

```
$ MIX_BUILD_ROOT=_build-expl11r2 mix test test/internal/expl11r2_wps_service_events_court_test.exs
...
Finished in 0.1 seconds (0.00s async, 0.1s sync)
Result: 3 passed
```

- F2: dead handler (real loopback port with no listener, real TCP reset)
  → witness event carries `delivered=false`, `delivery_status=~r/refused/`
  (bounded poll to terminal status; pending never asserted as truth).
- F3a: kill a member → `publish`/`members` prune it from raw
  `:sys.get_state`; publish returns `{:ok, 0}`.
- F3b: `Socket.terminate/2` run inside a real process → group membership
  drops; empty group/hub removed from raw state.

## Regression

```
$ MIX_BUILD_ROOT=_build-expl11r2 mix test test/internal/webpubsub_test.exs \
    test/internal/wps_exp4_court_test.exs \
    test/internal/expl11r2_wps_service_events_court_test.exs
Finished in 1.7 seconds (0.00s async, 1.7s sync)
Result: 20 passed
```

## Disclosures (compile-freeze SLA)

- `test/internal/wps_exp4_court_test.exs` (exp4 lane's file): my `groups`
  struct field broke its exact-struct pin; minimal unblock applied —
  the F6 join leg now pins unchanged fields
  (`%{st_after | groups: []} == %{st | groups: []}`) with an in-file
  disclosure comment. exp4 lane asked to re-pin or accept in its receipt.
- `lib/smalt/webpubsub/events.ex` was reconciled concurrently mid-lane
  (protocol shape flip-flopped between 3-tuple and 4-tuple casts);
  service.ex accepts both report shapes to be stable against either.

## Known-adjacent (NOT this lane's; pre-existing/other-lane)

- Census failures in the shared internal tier run trace to other lanes'
  in-flight files (`bkmaap6_nonce_bounds_court_test.exs` unregistered,
  `expl11r3_court_test.exs` unregistered + client-token violations).
- `lib/smalt/confidential_ledger/service.ex` had a transient syntax break
  (another lane, resolved by its owner within the SLA window).
- kafka/powl2 test failures in the internal-tier sweep are other lanes'
  surfaces (git status shows `law_compiler.ex` / `push_router.ex` modified
  by other lanes).

## Files

- lib/smalt/webpubsub/events.ex (leased; co-reconciled)
- lib/smalt/webpubsub/service.ex (leased)
- lib/smalt/webpubsub/socket.ex (F3-required extension, disclosed)
- test/internal/expl11r2_wps_service_events_court_test.exs (new court)
- test/internal/wps_exp4_court_test.exs (minimal unblock, disclosed)
- docs/jira/v26.10.22/receipts/expl11r2-wps-services.md (this receipt)
