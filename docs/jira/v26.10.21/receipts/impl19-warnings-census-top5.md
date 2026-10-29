# IMPL-19: warnings-census top-5 modules cleared

Context: solo

**Standing:** **PARTIAL_ALIVE** (top-5 modules at zero warnings; 66 smalt-owned warnings remain in untouched modules; tiers green)

Lane: WARNCLEAN (writer, OTP-29). Toolchain: Elixir 1.20.4-otp-29, Erlang/OTP 29 (erts-17.1.1), `MIX_BUILD_ROOT=_build-warncl`.

## Diff (5 files, all warning-driven)

- `lib/smalt/data_plane/kv_pss.ex` — pinned `db_len`/`h_len`/`top_bits`/`ps_len`/`s_len` in bitstring `size(...)` (6 pin-operator warnings → 0). Semantics unchanged.
- `lib/smalt/data_plane/file_share.ex` — moved `@max_share_guard_int` definition above its first use in `content_length_of/1` (undefined-module-attribute warning → 0); pinned `off`/`take` in `overlay/5` binary match. No guard-semantics change.
- `lib/smalt/data_plane/key_vault_actions.ex` — pinned `bits` in `ec_point_jwk/3` and `do_verify/3` matches; hoisted `coord = curve.coord` so `ec_public_point/2` can pin; removed compiler-proven-dead clauses: `check_encrypt_size/2` EC arm (encrypt_alg/2 already refuses EC upstream — the warning text itself is the unreachability proof), `kw_rand/3` and `do_kw/4` catch-alls (randomnumbers_alg only returns :ok for oct keys, so non-oct never reaches them), and the dead `err -> err` case arm. Behavior on every reachable input is identical: the only behavioral delta is that an input the compiler proved unreachable would now FunctionClauseError instead of returning 400 — unreachable means it cannot occur.
- `lib/smalt/messaging/amqp/connection.ex` — removed literal duplicate `props/op/body` assignment block in `handle_cbs/2` (unused-variable warnings, second block shadowed the first with identical values); pinned `size` in `chunk_binary/3`; removed type-proven redundant `_ -> nil` else-arm in `eh_sender_partition_key/1` (preceding `pk when pk != nil -> pk` already covers all).
- `lib/smalt/data_plane/blob_storage.ex` — removed never-matching `{:error, {:precondition, _}}` arm in `delete_blob/5` (Store emits the 1-tuple `{:error, {:precondition}}`, already handled by the arm directly above); `iso8601_to_epoch/1` error arm widened `{:error, _, _}` → `{:error, _}` (OTP-29/Elixir types `DateTime.from_iso8601` errors as 2-tuples `{:error, :invalid_format|...}`; `{:error, _}` also still matches a 3-tuple if a future OTP ever restores it); grouped the `parse_range_spec/3` clauses (suffix + span clauses moved up beside the first family, clause order preserved); removed never-used `include_metadata?(_) -> false` fallback (the `is_binary` clause is type-proven total at every call site).

## Before/after warning census (fresh compile, same build root)

`MIX_BUILD_ROOT=_build-warncl mix compile` (fresh `_build-warncl`, OTP-29):

| module | before | after |
|---|---|---|
| lib/smalt/data_plane/key_vault_actions.ex | 9 | **0** |
| lib/smalt/data_plane/kv_pss.ex | 6 | **0** |
| lib/smalt/messaging/amqp/connection.ex | 4 | 4 → **0** |
| lib/smalt/data_plane/file_share.ex | 4 | **0** |
| lib/smalt/data_plane/blob_storage.ex | 5 | **0** |
| smalt-owned total (all lib/smalt) | 94 | 66 |

Gate check: **zero new warnings** in touched modules (all at 0); warnings in untouched modules are pre-existing census entries, unchanged.

## Tier outputs

- kv tier (`kv_crypto_face`, `kv404_typed_error`, `kv_ec_create`, `kd62_udk_witness`): `Result: 15 passed`, exit 0
- blob tier (`blob_parity`, `blob_xml_error`, `blob_kd_fixes`, `kd130_container_exists`, `blob_sharedkey`): `Result: 34 passed`, exit 0
- amqp tier (`amqp_kd131_133_triage`, `kd155_delete_framing`, `kd134_requester_delivery`, `impl6_process_label`, `amqp_listener_cap`): `Result: 21 passed`, exit 0

## Disclosures

- Seven provably-unreachable clauses/arms removed, each backed by the compiler's own type/unreachability analysis on the OTP-29 toolchain (the task's stated bar), never judgment alone: key_vault_actions `check_encrypt_size/2` EC arm + `kw_rand/3`/`do_kw/4` catch-alls + dead `err -> err` case arm; connection.ex `eh_sender_partition_key/1` redundant `_ -> nil`; blob_storage never-matching `{:error, {:precondition, _}}` delete arm + `include_metadata?/1` fallback.
- The working tree carries pre-existing edits from other lanes (IMPL-5 AR-WIRE-02 in file_share.ex, amqp10 files, etc.); the diff hunks above are entirely this lane's. file_share.ex's UNBLOCK FIX comment pre-existed; this lane only relocated `@max_share_guard_int` above `content_length_of/1`.
- Toolchain note: default PATH elixir (1.19.5/OTP-28) refuses the repo (mix.exs requires ~> 1.20); runs used asdf `1.20.4-otp-29` + erlang `29.1.2`.

## Replay

```
export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-warncl mix compile            # 0 warnings in the 5 touched modules
mix test test/integration/kv_crypto_face_test.exs test/integration/kv404_typed_error_test.exs \
  test/integration/kv_ec_create_test.exs test/integration/kd62_udk_witness_test.exs        # 15 passed
mix test test/integration/blob_parity_test.exs test/integration/blob_xml_error_test.exs \
  test/integration/blob_kd_fixes_test.exs test/integration/kd130_container_exists_test.exs \
  test/integration/blob_sharedkey_test.exs                                                 # 34 passed
mix test test/integration/amqp_kd131_133_triage_test.exs test/integration/kd155_delete_framing_test.exs \
  test/internal/kd134_requester_delivery_test.exs test/internal/impl6_process_label_test.exs \
  test/internal/amqp_listener_cap_test.exs                                                 # 21 passed
```
