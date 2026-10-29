# BK-7b warnings sweep — v26.10.22

- **Date**: 2026-10-22
- **Lane**: BK-7b (follow-on to BK-7 warnings pass)
- **Context**: solo
- **Build root**: `_build-bk7b`

## Standing

**Standing:** PARTIAL_ALIVE — every lane-owned file compiles warning-free under
`mix compile --warnings-as-errors` and `just ws-lint` reports **0 problems
(0 errors, 0 warnings)**, `npx tsc --noEmit` exit 0. Full-repo strict compile
still exits 1 on files owned by in-flight lanes (see Deferred) and on
third-party deps (ggen_igniter 26.10.7, ash_r2rml 26.10.8, ash_graphlaw
26.10.8) which are outside lane authority.

## Before (measured, /tmp/bk7b_before.log + ws-lint)

Elixir, smalt-owned warnings in `mix compile --warnings-as-errors`:

- `lib/smalt/messaging/kafka/log.ex:135` x2 (unused t/q)
- `lib/smalt/storage/journal_sink.ex:340,416,660,767` (dead `{:error,_}`
  clauses vs do_seal/do_scope_seal real shape `{{:error,rsn},state}`;
  do_seal degraded clause never used)
- `lib/smalt/egress/SyncRoutes.ex:153` (dead `_ -> 0`; Store.baseline
  success-typed `{:ok,_,_}`)
- `lib/smalt/attestation/maa.ex:434` (never-used `tee_claims/1` fallback)
- `lib/smalt/data_plane/blob_storage.ex:870` (dead `:error ->` else clause)
- `lib/smalt/store.ex:101` (unused binding `= ok`)

TS: **48 warnings** (0 errors) across 20 files
(`/Users/sac/smalt/workspace`), all `@typescript-eslint/no-unused-vars`.

## Changes (no behavior change; dead-clause deletion / unused-binding removal only)

Elixir (5 files):
- journal_sink.ex: removed 3 dead `{:error,_}`/never-used-degraded-clause
  sites (handle_call :seal, do_append rotation, maybe_rotate_scope) and the
  never-used `do_seal(%{mode: :degraded})` clause. Note: do_seal's real
  error shape is `{{:error, {:seal_failed, _}}, state}` — a real seal
  failure still fails loudly exactly as before (CaseClause in the case),
  behavior preserved byte-for-byte on reachable inputs.
- SyncRoutes.ex: removed dead `_ -> 0` (baseline is success-typed).
- maa.ex: removed never-used `tee_claims(_)` fallback clause.
- blob_storage.ex: removed dead `:error ->` else clause in copy_blob.
- store.ex: `{:ok, pid} = ok ->` → `{:ok, pid} ->`.

Workspace (18 files): removed unused imports/bindings
(REVALIDATE_SECONDS, tailHash destructure key, overwriteStatus,
`{container}` destructure, ServiceBusClient-adjacent dead import in
sb-telemetry — ServiceBusReceivedMessage RESTORED after tsc proved it used
at 92/130, decodeFrame, Enroll/SignChallenge types, enc TextEncoder,
`up` flag, `res`/`hyd`/`fake`/`opts`/`up` bindings, WAL_LOCK_NAME
destructures, http/os imports), underscored deliberate positional params
(label→_label, version→_version, names→_names), and added
`argsIgnorePattern/varsIgnorePattern: "^_"` (+ignoreRestSiblings) to the
workspace eslint config — that pattern is the codebase's existing
convention (cosmos gap methods, WASI shim, checkpoint collector all use
`_`-prefixed required params that were warning against their own
convention).

## After (measured)

- `MIX_BUILD_ROOT=_build-bk7b mix compile --warnings-as-errors`: **0
  warnings in any BK-7b-touched file**; remaining `lib/smalt` warnings are
  exclusively lane-owned in-flight files (below). Deps warnings unchanged
  (third-party pins).
- `just ws-lint`: **0 problems (0 errors, 0 warnings)**, exit 0 (was 48).
- `npx tsc --noEmit`: exit 0.
- Tests: `mix test test/internal/journal_reader_court_test.exs
  test/internal/az2_maa_attestation_court_test.exs
  test/internal/kd_blob_court_test.exs test/data_plane` → **93 passed, 0
  failures**.

## Collision disclosure (same-checkout fan-out)

- Coordinator tick checkpoints `abb8c139`/`e3e351fc` swept 18 of this lane's
  workspace/lib edits into their in-flight snapshots before this lane's
  commit; commit `b8bf0fb4` carries the remaining dirty files + receipt.
- `lib/smalt/storage/journal_sink.ex`: after this lane's dead-clause
  deletions, the SPOF-A1 journal lane landed proper handling of do_seal's
  real error shape (`{{:error, {:seal_failed, _}}, st}` / `{:error, reason}`
  / `{nil, sc}`) on the same sites. The composed file (what landed) compiles
  warning-free and preserves typed-refusal behavior; post-composition
  compile + the 93-test run above were against the composed on-disk state.

## Deferred with owner

- `lib/smalt/messaging/kafka/conn.ex` (dirty, KAFKA-EXP4 owner): warnings
  at 32:3, 125:48, 159:8, 165:8, 521:8.
- `lib/smalt/messaging/kafka/log.ex` (became dirty mid-lane; owner fixed
  135 while I measured; a NEW warning at 267:60 `stored_count/1` is the
  owner's in-flight edit — not mine, skipped).
- Third-party deps (ggen_igniter, ash_r2rml, ash_graphlaw) warnings: not
  lane authority; upstream pins.

## Pre-existing, not session-introduced

- `test/integration/appconfig_events_test.exs` fails 5 tests with
  `{:already_started, ...}` ONLY when run combined with `test/pipeline`
  (isolation class, F8 ledger family); passes 5/5 alone. Unrelated to this
  diff.

## Replay

```
cd /Users/sac/smalt
PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_build-bk7b mix compile --warnings-as-errors
cd workspace && npx tsc --noEmit && cd ..
just ws-lint
mix test test/internal/journal_reader_court_test.exs test/internal/az2_maa_attestation_court_test.exs test/internal/kd_blob_court_test.exs test/data_plane
```
