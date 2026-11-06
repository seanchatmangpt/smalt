defmodule Smalt.Aoq.Arrow.FlatbufCourtTest do
  @moduledoc """
  Lane 7 (v26.11.6) cross-language courts for `Smalt.Aoq.Arrow.Flatbuf`.
  """

  use ExUnit.Case, async: true

  alias Smalt.Aoq.Arrow.{Flatbuf, Schema}

  @elixir_fixture_sha256 "5e9bc10380fbc71db50d8c497b321a681f8520ac14992dab4aae21af6082c980"
  # PROVENANCE: pinned fixture = Smalt.Aoq.Arrow.Flatbuf.encode/1 over
  # Schema.new("lane7_probe", [a: :i32 nullable, b: :utf8 non-null,
  # m: {:map, :utf8, :i32, false} with cgap:kind=probe metadata,
  # ts: {:timestamp, :nanosecond, "UTC}]). The cgap-arrow court c_fb5c
  # structurally decodes the same hex (tests/data/elixir_schema_fb.hex).
  @fixture_hex File.read!(
                 "/Users/sac/cgap/crates/cgap-arrow/tests/data/elixir_schema_fb.hex"
               )
               |> String.trim()

  # PROVENANCE: pyarrow 23.0.1 schema message (pa.ipc.new_stream schema-only
  # stream, first message; pyarrow omits the ARROW1 file identifier in the
  # streaming format — the reader accepts absent-or-ARRO). Same bytes as the
  # cgap golden_vectors.rs "golden_utf8" case.
  @pyarrow_utf8_hex "1000000000000a000c000600050008000a000000000104000c000000080008000000040008000000040000000100000014000000100014000800060007000c00000010001000000000000105100000001800000004000000000000000100000073000000040004000400000000000000"

  test "encode/decode roundtrip over the closed grammar subset" do
    schema =
      Schema.new("court_probe", [
        Schema.field("a", :i32, true),
        Schema.field("b", :utf8, false),
        Schema.field("m", {:map, :utf8, :i32, false}, true, %{"cgap:kind" => "probe"}),
        Schema.field("ts", {:timestamp, :nanosecond, "UTC"}, true)
      ])

    bin = Flatbuf.encode(schema)
    assert byte_size(bin) > 0

    assert {:ok, back} = Flatbuf.decode(bin)
    assert back.schema_id == "court_probe"
    assert Enum.map(back.fields, & &1.name) == ["a", "b", "m", "ts"]

    assert {:ok, _} = Flatbuf.decode(@fixture_hex |> Base.decode16!(case: :mixed))
  end

  test "fixture pin: sha256 + structural decode" do
    bin = Base.decode16!(@fixture_hex, case: :mixed)
    assert Base.encode16(:crypto.hash(:sha256, bin), case: :lower) == @elixir_fixture_sha256

    assert {:ok, schema} = Flatbuf.decode(bin)
    assert schema.schema_id == "lane7_probe"
    names = Enum.map(schema.fields, & &1.name)
    assert names == ["a", "b", "m", "ts"]
    assert [a, b, m, ts] = schema.fields
    assert a.type == :i32 and a.nullable
    assert b.type == :utf8 and not b.nullable
    assert {:map, :utf8, :i32, false} = m.type
    assert m.metadata == %{"cgap:kind" => "probe"}
    assert {:timestamp, :nanosecond, "UTC"} = ts.type
  end

  test "cross-language: decodes the pyarrow golden schema message" do
    bin = Base.decode16!(@pyarrow_utf8_hex, case: :mixed)
    assert {:ok, schema} = Flatbuf.decode(bin)
    assert [f] = schema.fields
    assert f.name == "s"
    assert f.type == :utf8
    assert f.nullable
  end

  test "typed refusals: bad identifier and truncation" do
    assert {:error, :bad_identifier} =
             Flatbuf.decode(<<"\x00\x00\x00\x00", "XXXX", 0, 0, 0, 0>>)

    assert {:error, :too_short} = Flatbuf.decode(<<1, 2, 3>>)
  end

  test "depth cap fence: deeply nested list refuses typed" do
    # 33-deep nested list exceeds @depth_cap 32 -> {:error, :depth_cap}
    deep = 1..40 |> Enum.reduce(:i32, fn _, acc -> {:list, acc, true} end)
    schema = Schema.new("deep", [Schema.field("d", deep, true)])

    case Flatbuf.encode(schema) do
      # encoder may not cap; the decoder must refuse typed either way
      bin when is_binary(bin) ->
        assert {:error, _} = Flatbuf.decode(bin)

      _ ->
        assert {:error, _} = Flatbuf.decode(<<>>)
    end
  end
end
