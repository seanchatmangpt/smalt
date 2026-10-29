# Receipt: bk7c-kafka-warnings

- **Lane**: BK-7C (`/Users/sac/smalt`)
- **Standing**: PASS
- **Context**: solo
- **Date**: 2026-10-22
- **Owner files**: `lib/smalt/messaging/kafka/conn.ex`, `lib/smalt/messaging/kafka/log.ex`, `lib/smalt/webpubsub/router.ex`

## Scope

Closes the BK-7b deferred-with-owner Kafka warnings (now unblocked: KAFKA-EXP4 repairs
landed) plus the Web PubSub router warning (wps-exp4 landed). Mechanical, no behavior
change; the one fail-closed fallback arm in scope was REPAIRED, not deleted (BK-7 rule).

## Before (measured, full `MIX_BUILD_ROOT=_build-bk7c mix compile`)

Smalt-owned warnings in lane-owned files:

- `lib/smalt/messaging/kafka/conn.ex:32:3` — unused `import Bitwise`
- `lib/smalt/messaging/kafka/conn.ex:125:48` — unused variable `cid`
- `lib/smalt/messaging/kafka/conn.ex:159:8` — `dispatch/2` clauses not grouped
- `lib/smalt/messaging/kafka/conn.ex:165:8` — `route/5` clauses not grouped
- `lib/smalt/messaging/kafka/conn.ex:516:8` — `parse_fetch/1` unused (dead arity)
- `lib/smalt/messaging/kafka/log.ex:266:60` — unused variable `stored` in `stored_count/1`
- `lib/smalt/webpubsub/router.ex` (via plug do_match) — `:error` clause can never match:
  `token_from_conn/1` returns `{:error, :missing}` while both case arms match bare `:error`

## After (measured)

- conn.ex: dropped unused `import Bitwise`; `cid` -> `_cid`; moved the
  `dispatch(_req, state)` fail-closed catch-all to directly follow the specific binary
  clause (regrouping only — clause order preserved: specific before catch-all); route
  clauses now contiguous. NOTE: an intermediate state put the catch-all FIRST and the
  compiler correctly refused it (clause cannot match) — caught and corrected in-lane
  before any test ran.
- conn.ex `parse_fetch`: the fail-closed fallback arm `do: :kill` was NOT deleted — its
  arity was dead (/1 vs the /2 call site). Repaired to `parse_fetch(_, _)` so the typed
  `:kill` fallback is reachable again. Strictly fail-closed improvement: malformed Fetch
  bodies now answer the typed `kill(state, :malformed_fetch_request)` path instead of an
  untyped FunctionClauseError crash.
- log.ex: dropped the dead `= stored` binding (value unchanged: `Records.count(rest)`
  path and the `{:ok, 1}` fallback arm both intact).
- router.ex: `token_from_conn/1` missing-token arm returns bare `:error`, matching the
  shape both call-site arms already matched. No route behavior change (401 on missing
  token, verified by webpubsub_test.exs).

## Verification (real runs, this tree)

- `MIX_BUILD_ROOT=_build-bk7c mix compile --warnings-as-errors`:
  **0 warnings in any BK-7C-touched file.** Remaining `lib/smalt` warnings are exclusively
  other lanes' in-flight files (`amqp/sas_verifier.ex:223` — amqp lane; `Mcp.Router`,
  `Egress.KvRoutes`, `EgressRouter` invoke-clause type warnings — mcp/egress lanes) and
  third-party deps (ggen_igniter 26.10.7, ash_r2rml 26.10.8, ash_graphlaw 26.10.8) +
  5 `.erl` deprecated-catch warnings (pre-existing, not lane authority).
- `MIX_BUILD_ROOT=_build-bk7c mix test test/internal/kafka_exp4_court_test.exs
  test/internal/wps_exp4_court_test.exs test/internal/webpubsub_test.exs`
  → **23 passed, 0 failures** (includes the KAFKA-EXP4 real-binary F3/F4 falsifiers and
  the KD-166 subprotocol/wrong-audience legs).

## Explicitly not lane-owned (left for owners)

- `lib/smalt/messaging/amqp/sas_verifier.ex:223` clause grouping (file dirty in the
  amqp lane's lease at measure time).
- `Smalt.Mcp.Router` / `Smalt.Egress.KvRoutes` / `Smalt.EgressRouter` invoke-clause type
  warnings (router-generated, modules not in this lane's lease).
- Deps + `.erl` warnings: third-party pins.

## Collision disclosure (same-checkout fan-out)

Coordinator tick checkpoint `36a8b74c` swept this lane's three lib edits
(kafka conn.ex/log.ex, webpubsub router.ex) into its in-flight snapshot
before this lane's commit; lane commit `9dc77e5c` therefore carries the
receipt only. The composed on-disk state is what was verified (strict
compile + 23-test court run above were against the composed tree).

## Replay

```bash
cd /Users/sac/smalt
PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_build-bk7c mix compile --warnings-as-errors
MIX_BUILD_ROOT=_build-bk7c mix test test/internal/kafka_exp4_court_test.exs \
  test/internal/wps_exp4_court_test.exs test/internal/webpubsub_test.exs
```
