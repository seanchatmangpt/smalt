# KD-28 ARM NSG shape — witness receipt (K5, v26.10.20)

**Standing:** ALIVE (fix landed + wire-witnessed)
Context: solo
Date: 2026-10-20

## Disposition: FIX

Row (v26.10.14 register): malformed NSG PUT admitted 201 (NsgShape
`sh:closed false`, no required paths). Falsifier: malformed PUT -> 400.

## Change

- `priv/shacl/smalt-shapes.ttl` — NsgShape tightened: `sh:closed true`,
  `location` minCount 1, `tags` + `properties.securityRules` declared
  (minCount 0). Boundary documented: securityRules ARRAY ITEMS are not
  descended by the evaluator (minCount/closed cannot reach list elements).
- `lib/smalt/arm_gateway/router.ex` — `# KD-COVERS: KD-28` marker at the
  GraphLaw 400 refusal site (ttl is compile-time parsed by the router's
  Validator).

## Witness (ephemeral witness beam, arm_port 39780; live substrate untouched)

    == KD-28 malformed (expect 400)
    400 {"error":{"code":"InvalidResourceShape","details":[{"code":"InvalidResourceShape","message":"unknown property path zzz (shape is sh:closed)"...
    == KD-28 conforming (expect 201)
    201
    == NSG PUT missing location (expect 400)
    400 {"error":{"code":"InvalidResourceShape","message":"networkSecurityGroups require location."...

Baseline-contrast: pre-fix identical PUT with `"zzz":1` was admitted 201 on
the live substrate (probed 2026-10-20, k5 lane, before the ttl edit).

## Tests

    15 tests, 0 failures  (test/integration arm-facing files, MIX_BUILD_ROOT=_build-k5)

## Notes

- Failures in test/internal cosmos_analytical_ttl + internal_tier_census
  during the same run are the sibling lane's in-flight data_plane/cosmos.ex
  surface, not this lane's diff.

Verdict: PASS (malformed PUT -> 400 typed; conforming PUT -> 201).
