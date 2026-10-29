# EXPL-5 R2 — T3/T4/T5 repairs (LawCompiler guard, PushRouter ingest, KQL error contract)

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: EXPL5-R2 (canonical checkout /Users/sac/smalt, MIX_BUILD_ROOT=_build-expl5r2)
- **Tickets**: EXPL5-T3/T4/T5 from `docs/jira/v26.10.22/receipts/expl5-dataplane-errc.md`

## Diffs

1. **T3 — `lib/smalt/powl2/law_compiler.ex` `build_guard/2`** (preferred option (b)
   from the ticket): the compiled guard now fails non-map input with a typed
   violation `{"<Shape>/datatype/$", "non-map data (...)"}` instead of matching
   vacuously. Fixes every consumer (PushRouter sieve at
   `push_router.ex:266` included). Map behavior unchanged.
2. **T4 — `lib/smalt/eventgrid/push_router.ex` `ingest/1`**: `ingest(_other)`
   returns the typed refusal `{:error, :invalid_events}` instead of a
   zero-count success. `@spec` and moduledoc updated; the sole production
   caller (`event_grid_webhook.ex:322`) discards the result, so no call-site
   change needed.
3. **T5 — `lib/smalt/data_plane/kql.ex:82`**: catch-all `run/2` clause returns
   `{:error, {:limit, "query must be a string, rows a list"}}`, restoring the
   documented `{:parse | :limit, msg}` contract shape.

## Embedded probe output (real, `mix run --no-start`, this session)

```
== EXPL5-T3: compiled guard on non-map data ==
guard.(%{"actor" => "a", "approver" => "b"}) -> :ok
guard.([]) -> {:violation, "ApprovalShape/datatype/$", "non-map data (list of 0)"}
guard.("str") -> {:violation, "ApprovalShape/datatype/$", "non-map data (string)"}
guard.(42) -> {:violation, "ApprovalShape/datatype/$", "non-map data (number)"}
== EXPL5-T4: PushRouter.ingest/1 non-list ==
ingest("oops") -> {:error, :invalid_events}
ingest(42) -> {:error, :invalid_events}
== EXPL5-T5: KQL.run/2 off-contract ==
run(%{}, %{}) -> {:error, {:limit, "query must be a string, rows a list"}}
```

## Court

`test/internal/expl5r2_court_test.exs` (registered in
`internal_tier_census_test.exs` as `:internal` + observables rows) — 5 tests:

- T3: `[]`, `["a"]`, `"str"`, `42`, `3.14`, `nil`, `:atom` all refused with
  rule =~ ApprovalShape + detail =~ non-map data; positive control (map → :ok);
  non-vacuity control (real notEquals breach still violates).
- T4: binary/integer/atom-keyed map → `{:error, :invalid_events}`.
- T5: tagged `{:limit, msg}` shape; tag in [:parse, :limit].

```
$ MIX_BUILD_ROOT=_build-expl5r2 mix test test/internal/expl5r2_court_test.exs
Result: 5 passed
```

## Regression (all green, same build root)

```
mix test test/internal/powl2_law_guard_court.exs test/internal/kql_test.exs \
    test/data_plane/kql_test.exs test/integration/eventgrid_push_court.exs
Result: 30 passed

mix test test/eventgrid test/data_plane
Result: 59 passed

mix run test/integration/graphlaw_skeptic_court.exs + w3cc_acp_court.exs (LawCompiler consumers)
exit=0, W3C-C COURT: PASS (incl. leg B: smalt LawCompiler compiled-guard legs)
```

## Pre-existing failures (NOT session-introduced, disclosed)

- `test/internal` full-tier run: 338/378 with failures in kafka_exp4/kafka_wire
  (another lane's in-flight `lib/smalt/messaging/kafka/*` edits), ETS/ARD timing
  courts, and the **internal-tier census** — the census was already red before
  my edits (unregistered in-flight files `expl5r1_court_test.exs`,
  `bk3_jsonsax_court_test.exs`, `kafka_exp4_court_test.exs`, `expl6r1_journal_court_test.exs`,
  `bkvc/kd_blob/kd_conf/wps/wire_exp4` from other lanes). My file is registered
  and contributes zero census violations. Witnessed: first census run (before
  any census edit by me) failed with the same foreign-file violation sets.
- Compile-freeze disclosure: I edited the shared census file
  (`test/internal/internal_tier_census_test.exs`) to add ONLY my lane's rows
  (registration + 3 observables entries).

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"
MIX_BUILD_ROOT=_build-expl5r2 mix run --no-start /tmp/expl5r2_probe.exs
MIX_BUILD_ROOT=_build-expl5r2 mix test test/internal/expl5r2_court_test.exs
```
