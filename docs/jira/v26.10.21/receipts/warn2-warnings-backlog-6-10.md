# WARN2 — Warnings backlog items 6-10 (IMPL-19)

Context: solo

**Standing:** **ALIVE** (target modules zero compile warnings; owning tiers green)

## Scope

Fresh compile census under `MIX_BUILD_ROOT=_build-warn2`
(Elixir 1.20.4-otp-29, Erlang 29.1.2), full `--force` recompile, stderr captured.
WARNCLEAN's receipt was not found on disk (`docs/jira/v26.10.21/receipts/` has no
WARNCLEAN file), so the census is fresh, not inherited.

## Before / after counts (warning sites per module)

| module | before | after |
|---|---|---|
| lib/smalt/egress_router.ex | 3 | 0 |
| lib/smalt/data_plane/queue_storage.ex | 3 | 0 |
| lib/smalt/messaging/amqp/frame_codec.ex | 2 | 0 |
| lib/smalt/egress/KvRoutes.ex | 2 | 0 |
| lib/smalt/arm/resource_providers.ex | 1 | 0 |
| lib/smalt/data_plane/cosmos_query_metrics.ex | 1 | 0 |
| total | 12 | 0 |

After-gate command (grep count over stderr of incremental `mix compile`):

```
MIX_BUILD_ROOT=_build-warn2 mix compile 2>&1 >/dev/null | grep -cE "lib/smalt/(egress_router|data_plane/queue_storage|messaging/amqp/frame_codec|egress/KvRoutes|arm/resource_providers|data_plane/cosmos_query_metrics)"
0
```

## Diff (per file)

- `lib/smalt/messaging/amqp/frame_codec.ex:498-499` — pin-operator fix:
  `<<frame::binary-size(^size), ...>>` and `<<_::binary-size(^header_bytes), ...>>`
  in plain `=` matches.
- `lib/smalt/egress/KvRoutes.ex:183` — pin `^bits` twice in the
  `<<4, x::unsigned-big-size(^bits), y::unsigned-big-size(^bits)>> = pub_point` match.
- `lib/smalt/egress_router.ex:821` — unused `conn` -> `_conn` in the guard-head
  clause of `content_length_admitted?/3` (second clause still uses `conn`).
- `lib/smalt/egress_router.ex` (file_dispatch get_share_props / get_dir_props) —
  deleted the redundant `{:ok, st, h, b} -> send_file_xml` clauses. Provably dead:
  `FileShare.get_share_properties/1` and `get_directory_properties/2` return
  `nil` body on every `{:ok, ...}` path (compiler success-type inference confirms;
  verified against both implementations).
- `lib/smalt/data_plane/queue_storage.ex:139, 392` — the `{:error, _, _, _} = err`
  else clauses in `delete_queue/2` and `clear_messages/2` were compiler-provably
  dead AND `{:error, :store_not_ready}` (the actual failure from `ready!/0`) had
  no matching clause — a latent `WithClauseError` when the store is not ready.
  Replaced with `{:error, :store_not_ready} = err -> err`. This is a correctness
  repair, not just a warning silence.
- `lib/smalt/data_plane/queue_storage.ex:249` — `parse_ttl/1` is total over all
  inputs and never returns nil/false; `|| @default_ttl_ms` RHS was provably dead.
  Dropped the `||` fallback.
- `lib/smalt/arm/resource_providers.ex:26` — `@type record` overrides a built-in;
  renamed to `@type provider_record` and updated the three @spec references.
- `lib/smalt/data_plane/cosmos_query_metrics.ex:70` — the `@doc` preceding
  `@spec request_charge` was being consumed by the private `defguardp int_in/3`
  (compiler reports it as "defmacrop int_in/3 is private, @doc discarded").
  Moved the `@doc`+`@spec` pair below the `defguardp` so the doc lands on
  `request_charge/1` as intended.

## Disclosures

- **Over-match reverted (self-caught)**: the batch replacement for the
  queue_storage dead clauses hit a third identical else block in
  `put_message/4`, whose callees (`parse_message_text`, `check_message_size`)
  legitimately return 4-tuple errors. Reverted that site to carry BOTH clauses
  (`{:error, :store_not_ready}` passthrough — silently missing before — plus
  the live 4-tuple passthrough). Strictly safer than the original.
- **Shared-compile freeze (other lanes, disclosed not owned)**: at session start
  `key_vault_actions.ex` (WARNCLEAN's file) was mid-edit and did not compile, and
  later `messaging/amqp10/frame_decoder.ex` was transiently corrupted by an
  in-flight shim-court mutation. Both self-resolved; I bounded-polled the compile
  (no file touched by this lane) before running gates.
- **Arm tier flake, disclosed**: first arm-tier run was 15/16 (one failure under
  concurrent-lane ETS churn, `init got unexpected: {:ETS-TRANSFER, ...}` log
  noise); immediate rerun 16/16.
- **Out-of-scope observed failure (pre-existing, not mine)**:
  `test/integration/amqp10_debug_test.exs` fails in its own harness
  (`grab/4` builds an improper list, `:lists.flatten` FunctionClauseError);
  test file is unmodified and the surface is WARNCLEAN's frame_decoder item,
  not this lane's `messaging/amqp/frame_codec.ex`. Not fixed (out of scope).

## Tier outputs

- queue tier: `mix test test/integration/queue_message_ct_test.exs
  test/integration/t27lq_list_queues_feed_test.exs` -> **9 passed**
  (re-run queue_message_ct alone -> 3 passed)
- kv tier: `mix test test/integration/kv_crypto_face_test.exs
  kv_ec_create_test.exs kv404_typed_error_test.exs` -> **11 passed**
- arm tier: `mix test test/internal/armstrong_idiom_court_test.exs
  arm_dcr_test.exs arm_workspace_tables_test.exs sb_arm_rules_test.exs`
  -> first run 15/16 (flake, disclosed), rerun **16 passed**
- adjacent surfaces (disclosure sweep, not required): amqp_kd131_133_triage ->
  7 passed; cross-surface/cosmos_k2 -> 4 passed;
  amqp10_debug -> 1 failed (pre-existing harness bug, see disclosures)

## Commit absorption note

The coordinator absorbed this lane's working-tree edits into checkpoint commits
`a448c8c` / `cf8044e` while gates were running (lane law: coordinator owns git).
All fixes verified present in HEAD and recompiled warning-free post-commit.

## Falsifier

Re-run the census command above; any target-module warning line reappearing
reopens this receipt.
