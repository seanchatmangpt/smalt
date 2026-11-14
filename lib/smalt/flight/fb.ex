defmodule Smalt.Flight.FB do
  @moduledoc """
  Minimal back-to-front FlatBuffers builder (just enough for Arrow IPC
  Schema/RecordBatch messages). Offsets are "size from end" values.
  """

  def new, do: <<>>
  def size(b), do: byte_size(b)

  def prep(b, align, extra) do
    pad = rem(align - rem(byte_size(b) + extra, align), align)
    <<0::size(pad * 8), b::binary>>
  end

  def u8(b, v), do: <<v::8, b::binary>>
  def i16(b, v), do: prep(b, 2, 0) |> then(&<<v::16-signed-little, &1::binary>>)
  def i32(b, v), do: prep(b, 4, 0) |> then(&<<v::32-signed-little, &1::binary>>)
  def i64(b, v), do: prep(b, 8, 0) |> then(&<<v::64-signed-little, &1::binary>>)

  def uoffset(b, off) do
    b = prep(b, 4, 0)
    rel = byte_size(b) + 4 - off
    <<rel::32-little, b::binary>>
  end

  def string(b, s) do
    b = prep(b, 4, byte_size(s) + 1)
    b = <<s::binary, 0, b::binary>>
    b = <<byte_size(s)::32-little, b::binary>>
    {b, byte_size(b)}
  end

  @doc "Vector of tables/strings given their offsets, in element order."
  def offset_vector(b, offs) do
    n = length(offs)
    b = prep(b, 4, 4 * n)
    b = offs |> Enum.reverse() |> Enum.reduce(b, &uoffset(&2, &1))
    b = <<n::32-little, b::binary>>
    {b, byte_size(b)}
  end

  @doc "Vector of inline structs (each a binary of elem_size, 8-aligned)."
  def struct_vector(b, structs, elem_size) do
    n = length(structs)
    b = prep(b, 4, elem_size * n) |> prep(8, elem_size * n)
    b = structs |> Enum.reverse() |> Enum.reduce(b, fn s, acc -> <<s::binary, acc::binary>> end)
    b = <<n::32-little, b::binary>>
    {b, byte_size(b)}
  end

  @doc "fields: [{slot, {:u8|:bool|:i16|:i32|:i64|:off, value}}]"
  def table(b, fields) do
    start = byte_size(b)

    {b, locs} =
      Enum.reduce(fields, {b, %{}}, fn {slot, {kind, v}}, {acc, m} ->
        acc =
          case kind do
            :u8 -> u8(acc, v)
            :bool -> u8(acc, if(v, do: 1, else: 0))
            :i16 -> i16(acc, v)
            :i32 -> i32(acc, v)
            :i64 -> i64(acc, v)
            :off -> uoffset(acc, v)
          end

        {acc, Map.put(m, slot, byte_size(acc))}
      end)

    b = prep(b, 4, 0)
    b = <<0::32, b::binary>>
    table_loc = byte_size(b)
    nf = if locs == %{}, do: 0, else: Enum.max(Map.keys(locs)) + 1

    b =
      Enum.reduce((nf - 1)..0//-1, b, fn slot, acc ->
        v = case locs do
          %{^slot => l} -> table_loc - l
          _ -> 0
        end
        <<v::16-little, acc::binary>>
      end)

    b = <<(table_loc - start)::16-little, b::binary>>
    b = <<((nf + 2) * 2)::16-little, b::binary>>
    vt_loc = byte_size(b)
    pos = byte_size(b) - table_loc
    <<pre::binary-size(pos), _::32, post::binary>> = b
    b = <<pre::binary, (vt_loc - table_loc)::32-signed-little, post::binary>>
    {b, table_loc}
  end

  @doc "Finish with root table offset; result size is a multiple of 8."
  def finish(b, root) do
    b = prep(b, 8, 4)
    uoffset(b, root)
  end
end
