# Receipt: v261019-C12 — Event Hubs consumer-group engine (lane C12)

- **Standing**: ALIVE
- **Repo**: /Users/sac/smalt (canonical checkout, no git actions; commit-ready diff)
- **Build root**: `_build-lane-c12` (reused warm)
- **Date**: 2026-10-19
- **Exclusive ownership honored**: `lib/smalt/messaging/event_hubs.ex` only (+ new
  test file `test/internal/event_hubs_consumer_groups_test.exs` + census seam registration).

## Scope delivered

Consumer groups are first-class engine records in `Smalt.Messaging.EventHubs`
(key `{hub, group}` in new server-owned table `:smalt_eh_cgs`), matching the
ARM consumergroup surface (`router.ex` PUT/GET/LIST/DELETE at
`.../eventhubs/:hub/consumergroups/:name`, which stores to `:smalt_resources`):

- `create_consumer_group/3` (idempotent re-PUT preserves created ts),
  `get_consumer_group/2`, `list_consumer_groups/1`, `delete_consumer_group/2`,
  `consumer_group_exists?/2`.
- `$default` auto-exists (lazily seeded inside the serialized server — no
  caller-side `:ets` writes, same lens-5 discipline as checkpoints).
- `reserve_processing/5` (hub, group, partition, owner, ttl): validates group
  existence; unknown group → typed `ConsumerGroupNotFound` face (status 404,
  `amqp:not-allowed`), no claim row written. Legacy `reserve_processing/4`
  unchanged (claim-blind).
- `consumer_group_face/1`: the wire-face builder for the AMQP attach path
  (`{hub}/ConsumerGroups/{cg}/Partitions/{n}` attaches; same
  echo-attach + typed-detach shape as the partition-pin refusal in
  `connection.ex`, which connection-lane can adopt — not edited, not owned).
- Group delete cascades the group's `{group, partition}` checkpoint rows
  (hub-prefixed partition keys only; legacy bare keys left to `sweep/0`).
- `$default` delete refuses typed 409 `ConsumerGroupNotDeletable`.

Per-group ownership: checkpoints/claims were already keyed `{group, partition}`;
verified with a real two-groups-one-partition reserve witness (T5).

## Witness (mix run, exit 0)

```
T1 $default implicit: name=$default created_ms=1792471924351
T2 create+idempotent rePUT: created_preserved=true
T3 unknown face: {404, "ConsumerGroupNotFound", "amqp:not-allowed"}
T4 list: ["billing", "$default"]
T5 per-group ownership: same-partition two groups ok, same-group other owner -> {:error, :conflict}
T6 reserve unknown group: {404, "ConsumerGroupNotFound"} claim_row_absent=true
T7 $default undeletable: {409, "ConsumerGroupNotDeletable"}
T8 delete+cascade: {404, "ConsumerGroupNotFound"}
T9 sweep: 0
```

## Gates

- `mix compile` — green, zero warnings from event_hubs.ex (handle_call clause
  grouping + unused-attribute warnings fixed in-lane).
- `mix test test/internal/event_hubs_consumer_groups_test.exs
  test/internal/internal_tier_census_test.exs` → **13 tests, 1 failure** (x3 runs,
  stable); the 1 failure is 100% certificates-lane-owned (`assert` lines with
  status literals in `certificates_kd104_witness_test.exs`). My 7 tests pass in
  every ordering.
- Full internal tier: `29 tests, 2 failures` — both certificates-lane-owned
  (census status-literal items + `CertificatesKd104WitnessTest` MatchError
  against their in-flight `lib/smalt/data_plane/certificates.ex`).
  **Zero failures attributable to lane C12.**

## Shared-file seams (disclosed)

- `test/internal/internal_tier_census_test.exs`: registered
  `event_hubs_consumer_groups_test.exs` (mine) and
  `certificates_kd104_witness_test.exs` (cross-lane unblock — their file was
  tripping the population fence and observables allowlist; disclosed here and
  must be mirrored in the certificates lane's receipt) in `@owned_files` /
  `@observables`. The remaining census failure is their content-level
  status-literal asserts — theirs to fix.
- Coordinator note: transient 429 mid-lane; lane resumed and completed.

## Files touched

- `lib/smalt/messaging/event_hubs.ex` (engine)
- `test/internal/event_hubs_consumer_groups_test.exs` (new, 7 tests)
- `test/internal/internal_tier_census_test.exs` (seam registration only)
