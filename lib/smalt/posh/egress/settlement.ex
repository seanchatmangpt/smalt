defmodule Smalt.Posh.Egress.Settlement do
  @moduledoc """
  Starboard Out settlement (POSH-002).

  @doc: v2 digest = pure-Elixir BLAKE3 (`Smalt.Posh.Blake3`, no NIF/hex dep).
  The receipt is exactly 32 bytes. Digest input is the cross-language contract
  byte string, no length prefixes, no separators:

      BLAKE3(op_utf8 || u64BE(timestamp_ns) || payload_body)

  settle/3 computes that digest and appends the receipt to the append-only
  event log (prev-hash chained).
  """

  @default_op "arm.request"

  @doc """
  Settles a delta into a 32-byte receipt.

  Opts: `:timestamp_ns` (default now), `:op` (default `"#{@default_op}"`),
  `:payload_body` (default canonical JSON of the delta), `:log_name`.
  Same inputs (including the same `:timestamp_ns` opt) produce the same
  receipt; a different `op`/`timestamp_ns`/`payload_body` produces a different
  receipt.
  """
  @spec settle(map(), String.t(), String.t(), keyword()) ::
          {:ok, %{receipt: <<_::256>>, timestamp_ns: integer(), emitted_at: String.t()}}
  def settle(delta, node_id, state_root, opts \\ [])
      when is_binary(node_id) and is_binary(state_root) do
    timestamp_ns = Keyword.get_lazy(opts, :timestamp_ns, fn -> System.system_time(:nanosecond) end)

    op = Keyword.get(opts, :op, @default_op)

    payload_body =
      Keyword.get_lazy(opts, :payload_body, fn -> Jason.encode!(delta) end)

    receipt = digest(op, timestamp_ns, payload_body)

    {:ok, _record} =
      Smalt.Posh.Egress.EventLog.append(Keyword.get(opts, :log_name, Smalt.Posh.Egress.EventLog), %{
        kind: "settlement",
        receipt: Base.encode16(receipt, case: :lower),
        node_id: node_id,
        state_root: state_root,
        timestamp_ns: timestamp_ns,
        delta: delta
      })

    {:ok,
     %{
       receipt: receipt,
       timestamp_ns: timestamp_ns,
       emitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  @doc """
  Pure digest computation (no log side effect). Cross-language contract:
  `BLAKE3(op_utf8 || <<timestamp_ns::unsigned-big-integer-size(64)>> ||
  payload_body)` — no length prefixes, no separators.
  """
  @spec digest(String.t(), integer(), binary()) :: <<_::256>>
  def digest(op, timestamp_ns, payload_body) when is_binary(op) and is_binary(payload_body) do
    Smalt.Posh.Blake3.digest_prefixed(
      op <> <<timestamp_ns::unsigned-big-integer-size(64)>> <> payload_body
    )
  end
end
