# EXPL10-R2 — EXPL-10 MED Repairs F4/F5/F10

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: EXPL10-R2, canonical checkout /Users/sac/smalt, `MIX_BUILD_ROOT=_build-expl10r2`

## Repairs

- **F4 (PushRouter scope over-match)** — `lib/smalt/eventgrid/push_router.ex`:
  `matching_subs/2` now matches on segment boundary
  (`source == scope or String.starts_with?(source, scope <> "/")`) via new
  `scope_matches?/2`; moduledoc matching-semantics line updated. Falsifier
  legs (real GenServer + real WAL delivery): scope `/smalt/prod` vs source
  `/smalt/prod2/x` → `matched: 0` / `no_match_events: 1` (EXPL-10 W3b
  witnessed `matched: 1` — flipped); `/smalt/prod` vs `/smalt/prod/x` and the
  exact source → `matched: 1, delivered: 1` (positive controls unchanged).
- **F5 (LawCompiler truncated TTL)** — `lib/smalt/powl2/law_compiler.ex`
  `split_statements/1`: a token stream exhausted before a terminal `.` with a
  non-empty trailing statement now raises `CompileError`
  ("truncated statement without final '.'") which `compile_shape/2` converts
  to `{:error, {:parse_error, _}}` per the module contract. Legs: truncated
  mid-shape TTL refuses; single unterminated statement refuses; trailing
  garbage after the last `.` refuses; full TTL compiles and the guard still
  enforces `sh:maxInclusive` (EXPL-10 W3a witnessed compile-ok — flipped).
- **F10 (Plug param validation)** — `lib/smalt/eventgrid/push_router.ex`
  (`PushRouterPlug.route/3` PUT/POST): `validate_params/1` runs BEFORE
  `put_subscription/4` dispatch — nil/blank `name` → 400
  `InvalidSubscriptionName`; non-binary `scope` → 400 `InvalidScope`;
  non-integer non-nil `destination.ttl_seconds` → 400 `InvalidDestination`
  (same JSON error-envelope idiom as the router's own refusals; previously
  FunctionClauseError → 500). `decode/1` guarantees a map, so no catch-all
  clause; compiles warning-free.

## Court

`PATH=$HOME/.asdf/shims:$PATH MIX_BUILD_ROOT=_build-expl10r2 mix test test/internal/expl10r2_court_test.exs`
(`test/internal/expl10r2_court_test.exs`, new, 11 tests). Embedded real output (verbatim):

```
...........
Finished in 0.07 seconds (0.00s async, 0.07s sync)

Result: 11 passed
```

Regression legs, same build root (verbatim):

```
mix test test/internal/powl2_law_compiler_court.exs test/internal/powl2_law_guard_court.exs \
  test/integration/eventgrid_push_court.exs test/internal/expl5r2_court_test.exs \
  test/internal/w2_dtdl_converter_court_test.exs
...
Finished in 0.2 seconds (0.00s async, 0.2s sync)

Result: 36 passed
```

## Notes

- Compile-freeze during the run: `lib/smalt/confidential_ledger/service.ex`
  (EXPL-11 lane's in-flight edit) transiently failed to compile
  (TokenMissingError); the owner landed a fix within minutes and this lane's
  gates then ran clean. No unblock fix applied by this lane; both lanes'
  receipts disclose the window.
- `test/internal/internal_tier_census_test.exs` shows 4 failures, all
  naming other lanes' files (`expl11r3_court_test.exs`,
  `expl11r_court_test.exs`, `bkmaap6_nonce_bounds_court_test.exs`) —
  pre-existing/other-lane, none touch push_router / law_compiler /
  expl10r2 (session-external, left in place).
- EXPL-10 findings owned by other lanes (F1/F2/F3 pipeline+powl2 executor,
  F6-F9 LOW) untouched here.
