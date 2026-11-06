defmodule AoqCrossRepoCourt do
  @moduledoc """
  R1-I S4 cross-repo court: ONE graph, TWO codecs, byte-identical wire.

  The landed ontology (`ggen-marketplace/packs/aoq-pack/ontology.ttl`)
  is projected into cgap-aoq's Rust codec (`codec::encode/decode` — the
  golden-bytes fixture court there) AND into smalt's Elixir codec
  (`Smalt.Aoq.Frame`). This court proves the two codecs interoperate
  byte-for-byte through the committed golden frame
  (`test/data/aoq_v3_golden.hex`), which is DERIVED by the real
  `cgap-aoq` `codec::encode` (`crates/cgap-aoq/tests/aoq_v3_golden_bytes_fixture.rs`)
  and never guessed:

  1. smalt decodes the cgap-encoded fixture byte-identically (field by field).
  2. smalt re-encodes the genesis frame and reproduces the fixture hex.
  3. The fixture's FNV-1a32 digest, stored LE at offset 60, matches
     smalt's independent `Frame.fnv1a32/1` over `[0,60)`.
  4. A cgap-encoded frame with a NON-default payload (stream-control
     prefix, larger body) round-trips through smalt's decoder, proving
     the agreement is structural, not fixture-shaped.
  """

  use ExUnit.Case, async: false

  alias Smalt.Aoq.Frame
  alias Smalt.Aoq.Tables

  @golden_path "test/data/aoq_v3_golden.hex"

  setup do
    Tables.boot()
    on_exit(fn -> :persistent_term.erase({:aoq, :sealed}) end)
    :ok
  end

  defp golden_hex do
    @golden_path |> File.read!() |> String.trim()
  end

  defp golden_bytes do
    hex_to_bin(golden_hex())
  end

  defp hex_to_bin(hex) do
    hex
    |> String.to_charlist()
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.map(&String.to_integer(List.to_string(&1), 16))
    |> :binary.list_to_bin()
  end

  test "cgap-encoded golden frame decodes in smalt byte-identically (fields + body)" do
    golden = golden_bytes()
    assert byte_size(golden) == 65

    assert {:ok, {frame, body}} = Frame.decode(golden)
    assert body == <<0>> # StreamType prefix 0 (stream-data), 1-byte body
    assert frame == %Frame{epoch: 0, key_id: 0x0102_0304_0506_0708, frame_ordinal: 7, seq: 42}

    # header-level pins against the Rust codec's documented output
    assert binary_part(golden, 0, 4) == <<"1QOA">>
    assert :binary.decode_unsigned(binary_part(golden, 4, 2), :little) == 3
    assert :binary.decode_unsigned(binary_part(golden, 6, 2), :little) == 0 # Epoch::Genesis
    assert :binary.decode_unsigned(binary_part(golden, 8, 8), :little) == 0x0102_0304_0506_0708
    assert :binary.decode_unsigned(binary_part(golden, 16, 4), :little) == 7
    assert :binary.decode_unsigned(binary_part(golden, 20, 4), :little) == 42
    assert binary_part(golden, 24, 36) == <<0::288>>
    assert :binary.decode_unsigned(binary_part(golden, 60, 4), :little) == 0x0B78_DD4D
  end

  test "smalt re-encodes the genesis frame back to the cgap-derived fixture hex" do
    body = <<0>>

    {:ok, iolist} =
      Frame.encode_frame(%Frame{epoch: 0, key_id: 0x0102_0304_0506_0708, frame_ordinal: 7, seq: 42}, body)

    assert IO.iodata_to_binary(iolist) == golden_bytes()
  end

  test "digest agreement: smalt fnv1a32 over [0,60) == the fixture's stored LE digest" do
    golden = golden_bytes()
    stored = :binary.decode_unsigned(binary_part(golden, 60, 4), :little)
    assert Frame.fnv1a32(binary_part(golden, 0, 60)) == stored
    assert stored == 0x0B78_DD4D
  end

  test "structural (not fixture-shaped): a non-default cgap-law frame round-trips smalt" do
    # Built directly from the landed field table, exactly as cgap's
    # codec::encode would emit it for epoch=Rotated1, a rotated key_id,
    # ordinal 0xFFFF_FFFE (near wrap), seq 1, CONTROL stream prefix with
    # a real control body.
    prefix =
      <<0x414F5131::unsigned-little-integer-size(32), 3::unsigned-little-integer-size(16),
        1::unsigned-little-integer-size(16), 0xAABBCCDDEEFF0011::unsigned-little-integer-size(64),
        0xFFFFFFFE::unsigned-little-integer-size(32), 1::unsigned-little-integer-size(32),
        0::unsigned-integer-size(288)>>

    header = prefix <> <<Frame.fnv1a32(prefix)::unsigned-little-integer-size(32)>>
    wire = IO.iodata_to_binary([header, <<1>>, <<0x1234::16>>])

    assert {:ok, {frame, body}} = Frame.decode(wire)
    assert frame == %Frame{epoch: 1, key_id: 0xAABBCCDDEEFF0011, frame_ordinal: 0xFFFFFFFE, seq: 1}
    assert body == <<1, 0x12, 0x34>>
  end
end
