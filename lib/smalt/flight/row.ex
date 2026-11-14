defmodule Smalt.Flight.Row do
  @moduledoc """
  Fixed 128-byte settlement row and its SHACL-style invariant
  `gross == sub + orig + fee + net` (checked before any encoding).
  """
  import Bitwise

  @row_bytes 128
  @pad_bytes 72
  @i64_min -(1 <<< 63)
  @i64_max (1 <<< 63) - 1
  @u64_max (1 <<< 64) - 1
  @i64_fields [:gross_cents, :sub_cents, :orig_cents, :fee_cents, :net_cents]

  def row_bytes, do: @row_bytes
  def pad_bytes, do: @pad_bytes

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(r) do
    with :ok <- ranges(r) do
      sum = r.sub_cents + r.orig_cents + r.fee_cents + r.net_cents

      if r.gross_cents == sum,
        do: :ok,
        else: {:error, {:invariant_violation, :gross_ne_sum, r.gross_cents, sum}}
    end
  end

  defp ranges(r) do
    cond do
      not (is_integer(r[:settlement_id]) and r.settlement_id in 0..@u64_max) ->
        {:error, {:bad_field, :settlement_id}}

      not (is_integer(r[:gate_mask]) and r.gate_mask in 0..@u64_max) ->
        {:error, {:bad_field, :gate_mask}}

      bad = Enum.find(@i64_fields, &(not (is_integer(r[&1]) and r[&1] in @i64_min..@i64_max))) ->
        {:error, {:bad_field, bad}}

      true ->
        :ok
    end
  end

  @spec encode(map()) :: {:ok, <<_::1024>>} | {:error, term()}
  def encode(r) do
    with :ok <- validate(r) do
      {:ok,
       <<r.settlement_id::64-little, r.gross_cents::64-signed-little,
         r.sub_cents::64-signed-little, r.orig_cents::64-signed-little,
         r.fee_cents::64-signed-little, r.net_cents::64-signed-little,
         r.gate_mask::64-little, 0::size(@pad_bytes * 8)>>}
    end
  end

  def decode(<<id::64-little, g::64-signed-little, s::64-signed-little, o::64-signed-little,
               f::64-signed-little, n::64-signed-little, m::64-little, _::binary-size(72)>>) do
    %{settlement_id: id, gross_cents: g, sub_cents: s, orig_cents: o, fee_cents: f,
      net_cents: n, gate_mask: m}
  end
end
