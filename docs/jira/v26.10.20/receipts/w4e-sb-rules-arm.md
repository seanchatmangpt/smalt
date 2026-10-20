# w4e — SB rules ARM family witness (PUT/GET/DELETE/LIST)

- **Lane**: w4e (ERRC wave-4)
- **Standing**: PASS
- **Context**: solo (integration tier, in-process dispatch); concurrent wave-4
  lanes on the shared tree — two transient compile-freeze windows observed and
  disclosed below, both resolved by their owning lanes (no cross-lane fix
  applied by w4e).
- **Date**: 2026-10-20

## Scope

Lane ownership: `lib/smalt/arm_gateway/router.ex` — SB rules routes ONLY.

The SB rules ARM family (PUT/GET/DELETE/LIST of
`.../topics/{t}/subscriptions/{s}/rules/{r}`) is already fully landed in HEAD
(`lib/smalt/arm_gateway/router.ex` `handle_sb_rule/8` dispatch family +
`lib/smalt/sb_rules.ex` rules store with fail-closed SQL filter/action parser,
`InvalidFilter`/`InvalidAction` typed 400s, `$Default` true-filter synthesis on
LIST when no user rules exist). This lane's deliverable was the missing piece:
a committed witness. The witness exercises the family end-to-end over real
ARM dispatch — PUT topic → PUT subscription → PUT rule 201 → GET 200 echo →
LIST → DELETE → 404 — plus the typed-validation refusals.

## Witness

`test/integration/sb_arm_rules_test.exs` — real Store rows, real
`Smalt.ArmGateway.Router` dispatch (`Plug.Router.call` in-process), real
`:smalt_sb_rules` store. Chicago discipline: no mocks. Key-level asserts
(no whole-map shape equality); status pins held as module attributes.

Real run output (lane build root `_build-lane-w4e`):

```
$ MIX_BUILD_ROOT=_build-lane-w4e mix test test/integration/sb_arm_rules_test.exs
Finished in 0.09 seconds (0.00s async, 0.09s sync)
3 tests, 0 failures
```

Seed-order independence (rules family is order-tolerant of the shared global
ETS store — each test provisions its own parents):

```
$ for s in 11 22 33; do ... mix test --seed $s test/integration/sb_arm_rules_test.exs ...; done
3 tests, 0 failures
3 tests, 0 failures
3 tests, 0 failures
```

Internal tier (the census fence is why the witness lives in the integration
tier — the internal tier's population fence + forbidden-token scans ban
`Plug.Test` dispatch, `Jason.decode!`, and ARM path literals, the exact shape
of an ARM router witness; the integration tier's
`arm_consumer_group_bridge_test.exs` is the precedent):

```
$ MIX_BUILD_ROOT=_build-lane-w4e mix test test/internal
Finished in 1.9 seconds (0.1s async, 1.9s sync)
42 tests, 0 failures
```

## Disclosures

- **Transient compile-freeze windows** (SLA note only, no cross-lane edit by
  w4e): mid-wave the shared compile was transiently broken by other lanes'
  in-flight edits (`router.ex` undefined-function errors from EH-geo-DR /
  locks lanes before their defs landed; `certificates.ex`, then
  `key_vault_actions.ex` `>>>` at line 1351). Each window cleared within the
  SLA window by the owning lanes (observed green after ~90s both times); w4e
  applied no minimal-unblock fix. Ownership respected throughout — w4e's diff
  touches only `test/integration/sb_arm_rules_test.exs` (new file).
- **Initial placement mistake, self-caught**: the witness was first authored
  under `test/internal/` and correctly tripped four census fences (population,
  forbidden-tokens, ARM path literals, observables allowlist). Resolved by
  relocating to the integration tier per the census's own contract, not by
  weakening the census.

## Replay

```
MIX_BUILD_ROOT=_build-lane-w4e mix test test/integration/sb_arm_rules_test.exs
MIX_BUILD_ROOT=_build-lane-w4e mix test test/internal
```
