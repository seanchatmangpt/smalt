# IMPL-19: Toolchain pin coherence census + warnings backlog

Context: solo

**Standing:** **ALIVE** (all pins admit the pinned toolchain; full tree compiles clean on 29.1.2, exit 0)

Toolchain: OTP **29.1.2** (erts 17.1.1) + Elixir **1.20.4-otp-29**, `~/.asdf/installs/erlang/29.1.2/bin` + `~/.asdf/installs/elixir/1.20.4-otp-29/bin`. MIX_BUILD_ROOT=_build-impl19.

## Pin diff (8 files, 20 insertions / 14 deletions)

| File | Before | After |
|---|---|---|
| `mix.exs:10` | `elixir: "~> 1.18 or ~> 1.19 or ~> 1.20"` | `elixir: "~> 1.20"` (+ comment at ~line 114 updated) |
| `proxy/mix.exs:8` | `elixir: "~> 1.17"` (REFUSES 1.20: `~> 1.17` caps < 1.18) | `elixir: "~> 1.20"` |
| `justfile.d/40-popcorn.just:41,70` | asdf `erlang/29.0.6` | asdf `erlang/29.1.2` (2 sites) |
| `scripts/have/storage_probe.py:79` | escript candidates: erlmcp otp-28.3.1, then PATH | asdf 29.1.2 first, erlmcp otp-28.3.1 fallback, then PATH |
| `scripts/stress/telemetry_overhead.py:26-31` | PATH head: erlmcp otp-28.3.1 | PATH head: asdf 29.1.2, then erlmcp 28.3.1 fallback |
| `scripts/bench/scvd_tier2.mjs:85` | machine `elixir 1.19.5 / otp 28` | `elixir 1.20.4-otp-29 / otp 29.1.2` |
| `scripts/bench/scvd_tier3.mjs:82` | same | same |
| `scripts/bench/t35_lro_contract.mjs:35` | same | same |

Already coherent (verified, no edit): `.tool-versions` (root + popcorn_demo) = `erlang 29.1.2 / elixir 1.20.4-otp-29`; `popcorn_demo/mix.exs` = `"~> 1.20"`.

Deliberately unchanged (compat seams / historical records):
- `lib/**/graph_compat`, `json_compat` engine dispatches — 28-compat fallback seams per task.
- `scripts/tprof_memory_gate.py:9`, `scripts/bench/t42_json.exs` — historical OTP 28.3.1 measurement notes, not pins.
- `justfile.d/40-popcorn.just:19` — accurate shadowing-hazard comment.
- `deps/ex4pm`, `deps/ash_ex4pm` (`"~> 1.17"`) — hex-owned, not lane-editable; note for the coordinator: hex ash_ex4pm 26.10.4 pins ex4pm `== 26.10.1` with `~> 1.17`; compile emits their warnings but builds clean.

## Warnings census (mix compile, full tree, 177 total)

Split: **68 smalt-owned** (`lib/smalt/**`), 109 dep-owned (ex4pm, plug, ash_phoenix, gen_stage, sweet_xml, rdf, toml, uuid, gen_state_machine...).

Top-10 cleanup backlog (smalt-owned, by file):

1. `lib/smalt/data_plane/key_vault_actions.ex` — 8: `bits accessed inside size(...)` needs pin operator (4 sites x2)
2. `lib/smalt/data_plane/kv_pss.ex` — 6: `top_bits` in size(...) pin-operator
3. `lib/smalt/messaging/amqp/connection.ex` — 4: clause-match warnings
4. `lib/smalt/data_plane/file_share.ex` — 3
5. `lib/smalt/data_plane/blob_storage.ex` — 3: `parse_range_spec/3` clauses not grouped (2) + 1
6. `lib/smalt/egress_router.ex` — 3
7. `lib/smalt/data_plane/queue_storage.ex` — 3
8. `lib/smalt/messaging/amqp/frame_codec.ex` — 2: size(...) pin-operator
9. `lib/smalt/egress/KvRoutes.ex` — 2: size(...) pin-operator
10. `lib/smalt/arm/resource_providers.ex` + `lib/smalt/data_plane/cosmos_query_metrics.ex` — 1 each

Recurring kinds: pin-operator-in-size(...) (~20), ungrouped same-arity clauses, unused require Logger, `xref: [exclude: ...]` deprecation (mix.exs — migrate to `elixirc_options: [no_warn_undefined: ...]`).

## Verification

```
$ PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH" \
  elixir --version
Erlang/OTP 29 [erts-17.1.1] ... Elixir 1.20.4 (compiled with Erlang/OTP 29)
$ MIX_BUILD_ROOT=_build-impl19 MIX_ENV=dev mix compile   → exit 0
```

Not done (out of scope): warning fixes (backlog above), hex dep bumps, coordinator-side git ops.
