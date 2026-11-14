defmodule Smalt.Flight.Arrow do
  @moduledoc """
  Pure Elixir Arrow IPC stream writer for settlement rows. Hand-built
  flatbuffers via Smalt.Flight.FB (no flatc). Columns: 7 x 64-bit ints plus
  `pad` FixedSizeBinary(72), so one logical row = 128 bytes.
  Columnar layout means the 128-byte row is logical, not contiguous (see KD-FLIGHT-1).
  Unverified against pyarrow in this lane (no compile/test run).
  """
  alias Smalt.Flight.{FB, Row}

  @cols [
    {"settlement_id", :u64, :settlement_id},
    {"gross_cents", :i64, :gross_cents},
    {"sub_cents", :i64, :sub_cents},
    {"orig_cents", :i64, :orig_cents},
    {"fee_cents", :i64, :fee_cents},
    {"net_cents", :i64, :net_cents},
    {"gate_mask", :u64, :gate_mask},
    {"pad", :pad, nil}
  ]

  def columns, do: Enum.map(@cols, &elem(&1, 0))

  @doc "Validates every row (invariant first), then returns the full IPC stream."
  def encode_stream(rows) when is_list(rows) do
    with :ok <- validate_all(rows) do
      {:ok, IO.iodata_to_binary([schema_message(), batch_message(rows), eos()])}
    end
  end

  defp validate_all(rows) do
    Enum.reduce_while(rows, :ok, fn r, _ ->
      case Row.validate(r) do
        :ok -> {:cont, :ok}
        {:error, e} -> {:halt, {:error, {r[:settlement_id], e}}}
      end
    end)
  end

  def eos, do: <<0xFFFFFFFF::32-little, 0::32>>

  defp field(b, {name, kind, _}) do
    {b, type_off} =
      case kind do
        :pad ->
          FB.table(b, [{0, {:i32, Row.pad_bytes()}}])

        k ->
          FB.table(b, [{0, {:i32, 64}}, {1, {:bool, k == :i64}}])
      end

    {b, name_off} = FB.string(b, name)
    type_type = if kind == :pad, do: 15, else: 2

    FB.table(b, [
      {0, {:off, name_off}},
      {1, {:bool, false}},
      {2, {:u8, type_type}},
      {3, {:off, type_off}}
    ])
  end

  def schema_message do
    {b, offs} =
      Enum.reduce(@cols, {FB.new(), []}, fn c, {acc, os} ->
        {acc, o} = field(acc, c)
        {acc, os ++ [o]}
      end)

    {b, fields_vec} = FB.offset_vector(b, offs)
    {b, schema} = FB.table(b, [{0, {:i16, 0}}, {1, {:off, fields_vec}}])
    message(b, 1, schema, 0, <<>>)
  end

  def batch_message(rows) do
    n = length(rows)
    {bufs, body, _} =
      Enum.reduce(@cols, {[], [], 0}, fn {_, kind, key}, {bs, body, off} ->
        data =
          case kind do
            :pad -> :binary.copy(<<0>>, Row.pad_bytes() * n)
            :u64 -> for r <- rows, into: <<>>, do: <<Map.fetch!(r, key)::64-little>>
            :i64 -> for r <- rows, into: <<>>, do: <<Map.fetch!(r, key)::64-signed-little>>
          end

        padded = pad8(data)
        validity = <<off::64-little, 0::64-little>>
        dbuf = <<off::64-little, byte_size(data)::64-little>>
        {bs ++ [validity, dbuf], [body, padded], off + byte_size(padded)}
      end)

    body = IO.iodata_to_binary(body)
    nodes = for _ <- @cols, do: <<n::64-little, 0::64-little>>
    {b, bufs_vec} = FB.struct_vector(FB.new(), bufs, 16)
    {b, nodes_vec} = FB.struct_vector(b, nodes, 16)

    {b, rb} =
      FB.table(b, [{0, {:i64, n}}, {1, {:off, nodes_vec}}, {2, {:off, bufs_vec}}])

    message(b, 3, rb, byte_size(body), body)
  end

  defp message(b, header_type, header, body_len, body) do
    {b, msg} =
      FB.table(b, [
        {0, {:i16, 4}},
        {1, {:u8, header_type}},
        {2, {:off, header}},
        {3, {:i64, body_len}}
      ])

    fb = FB.finish(b, msg)
    IO.iodata_to_binary([<<0xFFFFFFFF::32-little, byte_size(fb)::32-little>>, fb, body])
  end

  defp pad8(bin) do
    pad = rem(8 - rem(byte_size(bin), 8), 8)
    <<bin::binary, 0::size(pad * 8)>>
  end
end
