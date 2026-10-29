# BK-7: Compiler-Warning Cleanup (smalt-owned)

**Standing: PARTIAL_ALIVE** — zero smalt-owned warnings outside another lane's
lease; the single remaining `lib/smalt/apim.ex` warning is in a file owned by a
concurrent lane and was not touched. Compile still exits 1 under
`--warnings-as-errors` solely because of that lane's warnings + pre-existing
deps warnings.

`Context: solo`

## Census

- Command: `MIX_BUILD_ROOT=_build-bk7 mix compile --warnings-as-errors`
  (asdf Elixir 1.20.4-otp-29 / toolchain per `.tool-versions`; note the
  homebrew default `elixir` on PATH is 1.19.5 and refuses the build —
  asdf shims required).
- Before (fresh `_build-bk7`, full census incl. deps):
  `tmp/bk7-warnings.log` — 141 `warning:` lines; smalt-owned sites: 46 in
  `lib/smalt/` + 1 in `lib/mix/tasks/` = **47** (the backlog "68" figure was
  stale; measured fresh). No `test/` warnings existed.
- After (`tmp/bk7-final2.log`): 32 total, of which smalt-owned = **1**
  (`lib/smalt/apim.ex:59/67/73`, owned elsewhere). All deps warnings
  (`plug`, `ash_*`, `ggen_igniter`, `explorer`, …) are pre-existing and
  out of scope.

## Fixed (24 files, minimal type-safe edits)

Dead/unreachable clauses removed or corrected:
`data_plane/blob_service.ex` (3-tuple `from_iso8601` error arm),
`graphlaw/validator.ex` (`shape_name`), `data_plane/vault_data.ex`,
`data_plane/appconfig_events.ex`, `mcp/router.ex`, `monitor/app_insights.ex`,
`powl2/decomposition.ex`, `arm/export_template.ex`, `wasm/worker.ex`
(`runner_args_list` deletion + `_predicate_frames`),
`messaging/amqp10/amqp10_connection.ex`, `mix/tasks/smalt.court_emit.ex`
(case replaces a `with/else` whose `{:ok, :dropped}` arm was dead — the arm
moved into a `case` on `court_run/2`'s real return shape),
`runtime_contracts/amqp_dialect.ex` (assert value not type),
`enclave/engine.ex` — **latent bug**: `dispatch/3`'s `with`-else clause
`{:error,_}=err` could never match (`arm_target/4` never returns error
tuples), so an unknown resource type would raise `WithClauseError`; now
returns the typed `{:error, {:unknown_resource_type, type, label}}`.

Pin operator in bitstring sizes: `telemetry/sealed_log.ex` (^len),
`messaging/amqp10/frame_decoder.ex` (^n ×6, ^size, ^doff).

Unused vars underscored: `egress/SqlIngestRoutes.ex` (`_mapping_iri`),
`messaging/amqp10/amqp10_session.ex` (`_pid`),
`graphlaw/sql_row_gate.ex` (`_schema`), `telemetry/sealed_log.ex`
(`_payload`, dropped unused `require Logger`), `powl2/change_feed.ex`
(`_etag`; `@batch_limit` hoisted above `@moduledoc` so the @doc interpolation
resolves).

Type rename: `projection/admission.ex` `@type record` → `@type t` (was
overriding a built-in type name; internal @specs updated).

OTP-28-toolchain false positives silenced without behavior change:
`powl2/graph_compat.ex` native `:graph` leg now dispatches via `apply/3`
(module is OTP-29 stdlib; runtime availability still guarded by
`Code.ensure_loaded?/1` in `engine/0`).

Cross-lane unblock (disclosed): `messaging/amqp/queue_store.ex:405`
`seq` → `_seq` — a one-token unused-var warning introduced by another lane's
landed edit; file mtime stable 15+ min, not on the owned-elsewhere list.

## Real latent bugs found and fixed

1. `sql_ingest/mapping.ex` `tok/3`: `{string, rest2} ->` matches ANY 2-tuple,
   so `{:error, _}` from `read_string`/`read_iri` was dead — an unterminated
   string/IRI silently tokenized the error tuple as garbage tokens instead of
   returning the typed error. Error clauses now come first.
2. `enclave/engine.ex` `dispatch/3` (above).

Also: `amqp10_connection.ex` carried a comment claiming a `{:error, reason}`
return path for socket-death; `tx/3` actually raises (supervision handles
transport death) — dead clause deleted with a correcting comment.

## Verification

- `mix compile --warnings-as-errors` (final):
  remaining smalt-owned = apim.ex only. Output tail:

  ```
  warning: clauses with the same name and arity (number of arguments) should be grouped together, "def init/1" was previously defined (lib/smalt/apim.ex:59)
      │
   73 │   def init(opts), do: opts
      │       ~
      │
      └─ lib/smalt/apim.ex:73:7
  Compilation failed due to warnings while using the --warnings-as-errors option
  ```
- Tests over changed modules: `sql_ingest_mapping_court`,
  `powl2_decomposition_test`, `powl2_change_feed_test`,
  `powl2_graph_compat_court`, `appconfig_events_test` — **53 passed, 0
  failures**. `graphlaw_fullstack_court` passed; `storage_decoupling_court`
  50k-emit test timed out — reproduced with HEAD's `sealed_log.ex` too
  (baseline fail), so pre-existing/environment-load flake, not
  session-introduced.
- `arm_gateway/router.ex` broke mid-session under another lane's in-flight
  edit; owner repaired within the SLA window (observed compiling again on
  poll attempt 1). No intervention needed.

## Owned elsewhere (skipped)

- `lib/smalt/apim.ex` (3 warning lines: init grouping + 2× `@impl GenServer`
  without `@behaviour`) — lane lease on apim.ex.
- Other leased files (`atom_bridge`, `planes`, `egress_router`,
  `arm_gateway/router`, `seal`, `ledger_writer`, ja7/ja9/ja12) carried zero
  warnings in any census.

Not committed, per task order. `_build-bk7` left in place as a lane build
lease.
