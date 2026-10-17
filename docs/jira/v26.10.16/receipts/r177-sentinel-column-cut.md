# R177 — Sentinel column cut + query-entry cap

Standing: PASS

## Scope

`lib/smalt/data_plane/sentinel.ex` hardening: (1) query-length cap
(`@max_query_length 2_000`) enforced at the Sentinel entry point BEFORE any
literal-strip scan — covers the legacy non-pipeline path and the ReDoS
lane R175 E1/E3; (2) typed 400 `BadQuery` parse-error envelope for pipeline
queries without a leading pipe; (3) ordered project-column extraction with
quoted-string literals preserved.

## Re-run output (docs lane, 2026-10-16, `_build-lane207`)

```
$ MIX_BUILD_ROOT=_build-lane207 mix test test/data_plane/audit_planes_test.exs
Finished in 0.9 seconds (0.00s async, 0.00s sync)
82 tests, 0 failures
```

## Static witnesses

- `lib/smalt/data_plane/sentinel.ex` `@max_query_length 2_000` with the
  lane R175 E1/E3 comment (cap-before-scan).
- Typed `:parse_error -> 400 BadQuery` branch in `do_query/2`.
- Diff witness: cap + parse_error branches are additions on the in-flight
  tree (git diff of sentinel.ex), not pre-existing.

Two compile-freeze events (concurrent lanes: store.ex, then
test/test_helper.exs duplicate `wait_gone` defp) were waited out per the
compile-freeze SLA before the green re-run above; both cleared without
docs-lane intervention.
