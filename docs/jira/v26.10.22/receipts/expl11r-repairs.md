# EXPL11-R — repairs over EXPL-11 findings (F1–F4, co-lane fold)

- **Date**: 2026-10-22
- **Lane**: EXPL11-R, repo /Users/sac/smalt (canonical checkout; only the named lib/test/receipt files)
- **Source findings**: `docs/jira/v26.10.22/receipts/expl11-telemetry-planes-errc.md` (F1–F6)
- **Standing**: ALIVE
- **Context**: solo

## What landed (this lane's hands)

- **F2 (Web PubSub CloudEvents delivery truth)** — `lib/smalt/webpubsub/events.ex`
  rewritten: every witness event carries `"delivered"` (bool) +
  `"delivery_status"` (`"pending"` | `"no_handler"` | `"delivered"` |
  `"refused:<reason>"`). Delivery stays async, but `deliver/2` checks the real
  `:httpc` status (2xx ⇒ delivered) and casts the outcome back to the broker,
  which flips the witness by event id. No more success laundering of a dropped
  POST. Contract note: the `{id, delivered?, status}` cast contract on
  `Smalt.WebPubSub` is co-owned with EXPL11-R2's `service.ex` clause — see
  collision disclosure below.
- **F4 (empty plane selection refuses typed)** — `lib/smalt/planes.ex`
  `resolve/0`: config-path `[]` now raises `Smalt.Planes.InvalidPlane`
  (renders `{:invalid_plane, []}`), same class as an unknown name.
  `SMALT_PLANES=""` → `:all` unchanged; unknown name refusal (JA-R1) intact.
- **F1 / F3 / F5 repair code** landed via the concurrent R1/R2/R3 lanes over
  the same ticket set (ledger range validation + 400 boundary in
  `confidential_ledger/router.ex`+`service.ex`; WPS dead-pid prune +
  socket terminate-leaves; ledger `certify_segment` meta typed refusal). This
  lane's court legs for those tickets ride the R1/R2/R3 court files.

## Collision disclosures (compile-freeze SLA)

1. `events.ex` was found as a broken half-applied edit (duplicate `emit/5`,
   undefined `status`) — took ownership and rewrote it (disclosed fix, owner
   had abandoned it in broken state).
2. The `delivery_result` cast contract ping-ponged between this lane and the
   R2 lane three times during the window (3-tuple tagged vs 4-tuple flat).
   Final state: 4-tuple `{id, delivered?, status}`; my `events.ex` aligned to
   the on-disk `service.ex` clause. Final state compiles and passes both
   lanes' courts.
3. Census registry additions (`expl11r_court_test.exs` registered, comment
   reworded to clear the client-token scan) — the only census edits.

## Court (test/internal/expl11r_court_test.exs — 4 legs, all pass)

```
Result: 4 passed
```

- **F2+ positive leg (the anti-vacuity direction R2's dead-handler leg
  cannot show)**: real Bandit 200 handler on loopback + real POST ⇒ witness
  flips to `delivered == true`, `delivery_status == "delivered"`. A witness
  that can never show `true` would be as vacuous as one that always shows
  `true` — both directions witnessed.
- **F4**: `config :smalt, :planes, []` ⇒ raises `{:invalid_plane, []}`;
  `[:control]`/`:all`/`SMALT_PLANES=""` unchanged; `:bogus_plane` still
  refuses (JA-R1 regression leg).

## Sibling courts re-run (green at capture time)

```
expl11r2_wps_service_events_court_test.exs   Result: 4 passed  (3 tests + doctest)
expl11r1_ledger_range_court_test.exs         Result: 5 passed
az3_confidential_ledger_court_test.exs + az3b_ledger_mount_court_test.exs
                                             Result: 8 passed
```

## Typed notes for the owner

- **Census population fence currently RED** from OTHER lanes' unregistered
  in-flight files (`bkmaap6_nonce_bounds_court_test.exs`, `expl10r_court_test.exs`,
  `expl11r3_court_test.exs`) plus their own token-scan violations — not this
  lane's files; owners hold them. `expl11r_court_test.exs` itself passes all
  census scans.
- `expl11r3_court_test.exs` was mid-edit (5/13 failing on their own F5 legs)
  at capture time; owner lane holds it.
- F6 (OcelEmitter `cosmos.doc.crud` label drift): documented semconv deviation,
  no action per EXPL-11.
