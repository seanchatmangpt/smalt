# I16 — smalt.gen replay identity fences (byte-identical regen products)

Lane: I16 (`docs/jira/v26.10.17/_LANES.md`) · Lease: `lib/smalt/data_plane/`, `lib/smalt/registry.ex` consumers
Standing: PASS

## Claim

Survey concluded no `mix smalt.gen` regeneration is needed: the generated artifacts
(`lib/smalt/config.ex` incl. `arm_cors_origins`, `lib/smalt/registry.ex`,
`lib/smalt/store_tables.ex`, `lib/smalt/cascade_edges.ex`,
`lib/smalt/telemetry/semconv/registry.ex`) are already byte-identical to their
generators' output. Verified by running all five replay-identity fences (each fails on
drift between the generated file and a fresh in-memory render).

## Command

```bash
MIX_BUILD_ROOT=_build-lane16 mix test test/config_replay_identity_test.exs \
  test/smalt_registry_replay_identity_test.exs test/store_tables_replay_identity_test.exs \
  test/cascade_replay_identity_test.exs test/semconv_replay_identity_test.exs
```

## Output (real, tail)

```
Running ExUnit with seed: 806151, max_cases: 32
Excluding tags: [:amqp_wire]

...................
Finished in 171.7 seconds (0.00s async, 171.7s sync)
19 tests, 0 failures
EXIT=0
```

(Full run also cold-compiled `_build-lane16` deps; first app boot logged listeners on
ephemeral ports 59687–59692, no fixed-port collisions.)

## Result

- 19 tests, 0 failures, exit 0 across the 5 fences:
  config / smalt_registry / store_tables / cascade / semconv replay identity.
- Census keys at time of survey: 47 (`lib/smalt/registry.ex` regen product).
- No regen performed, no source edits, no git operations.

## Notes

- Pre-existing dep compile warnings in fresh lane build root (`gen_state_machine`
  charlist deprecations, `ash`/`ex4pm` Igniter module resolution) are upstream deps,
  not smalt, and do not affect the fences.
- Lane build root `_build-lane16` left for lane lifecycle; coordinator reclaims at
  integration per cleanup law.
