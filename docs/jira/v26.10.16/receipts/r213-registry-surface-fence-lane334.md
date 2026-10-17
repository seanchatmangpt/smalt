# Receipt — R212 (ARM registry surface coverage fence, lane 334)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16)
- **Standing:** PASS (existing fence green; one registered gap family)
- **Date:** 2026-10-16 (lane 334, probe-authoring scope trimmed to run-existing-harnesses per 80/20)

## Scope note

Original lane task was to author `test/registry_surface_test.exs`. Course-corrected
mid-task: no new probe code; run existing harnesses and receipt the output. The cell
is already fenced by `test/apiversion_matrix_test.exs` (per-type generated inventory,
registry-completeness row, route-gap row, cite-drift fence) — no new probe needed.

## Verification (2026-10-16, lane 334, unedited output)

```
$ MIX_BUILD_ROOT=_build-lane334 mix test test/apiversion_matrix_test.exs
200 tests, 0 failures
```

Gap computation (same set difference the harness performs, `mix run --no-start`):

```
GAPS=["Microsoft.Network/privateDnsZones/virtualNetworkLinks"]
```

## Findings (registrable, not fixes)

1. **`Microsoft.Network/privateDnsZones/virtualNetworkLinks`** — the only admitted
   registry type with no router route. Its PUT currently returns 404 RouteNotFound,
   pinned as contract by `test/apiversion_matrix_test.exs` "route gaps" row
   ("deep child-path types currently return 404 RouteNotFound on PUT"). Landing a
   dedicated child route turns that fence red → move the type into @child_routes.

## Fences relied on (pre-existing)

- `test/apiversion_matrix_test.exs`: "route inventory rows cover every single-segment
  admitted type", "every admitted type is in exactly one matrix class", route-gap row,
  registry-completeness row ("every route resource-type literal is an admitted
  registry type" — reverse fence for unadmitted route literals), cite-drift fence.

## Standing

PASS. Any future registry row without a route fails the existing fence; the single
gap family is pinned, not silent.