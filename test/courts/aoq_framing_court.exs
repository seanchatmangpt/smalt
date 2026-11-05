defmodule AoqFramingCourt do
  @moduledoc """
  LANE-13 byte-fidelity court for the AoQ framing + egress laws
  (aq-architecture-spec §2/§3).

  Asserts on the wire format itself, not on call counts:
  - header exactly 64 bytes, body ≥1 byte (RefcBinary framing law, §2)
  - encoded payloads ≥65 bytes total — HeapBin territory never entered
  - iolist egress produces byte-identical wire bytes to a `<>` reference
    encode (§3 fidelity)
  """
  use ExUnit.Case, async: true

  alias Smalt.Aoq.Frame

  @header_size 64

  defp ref_header, do: :crypto.strong_rand_bytes(@header_size)

  test "header size constant is exactly 64" do
    assert Frame.header_size() == 64
  end

  test "encode returns an iolist [header | payload], not a flat binary" do
    header = ref_header()
    payload = :crypto.strong_rand_bytes(200)

    assert {:ok, frame} = Frame.encode(header, payload)
    assert is_list(frame)
    assert frame == [header, payload]
    # iolist, not `<>`-concatenated binary
    refute is_binary(frame)
  end

  test "encoded frame is ≥65 bytes — RefcBinary territory, never a HeapBin" do
    # smallest lawful payload: 1 byte → 65 total
    {:ok, frame} = Frame.encode(ref_header(), <<0xFF>>)
    total = frame |> :erlang.iolist_size()
    assert total >= 65
    assert byte_size(IO.iodata_to_binary(frame)) >= 65
  end

  test "zero-length payload is refused (would total exactly 64 — HeapBin)" do
    assert {:error, :empty_payload} = Frame.encode(ref_header(), <<>>)
  end

  test "short header is refused" do
    assert {:error, :short_header} = Frame.encode(<<0::size(8 * 63)>>, <<1>>)
    assert {:error, :short_header} = Frame.encode("not-a-binary", <<1>>)
  end

  test "split round-trips a lawful frame" do
    header = ref_header()
    body = :crypto.strong_rand_bytes(97)

    wire = IO.iodata_to_binary([header, body])
    assert {:ok, ^header, ^body} = Frame.split(wire)
  end

  test "split refuses sub-65B frames (framing law violation, not a short read)" do
    # 64B header + 0B body
    assert {:error, :short_frame} = Frame.split(:crypto.strong_rand_bytes(64))
    # 63B total
    assert {:error, :short_frame} = Frame.split(:crypto.strong_rand_bytes(63))
  end

  test "byte fidelity: iolist egress == <> reference encode" do
    header = ref_header()
    payload = :crypto.strong_rand_bytes(1000)

    {:ok, iolist_frame} = Frame.encode(header, payload)
    reference = header <> payload

    assert IO.iodata_to_binary(iolist_frame) == reference
  end

  test "payload sizes spanning the 64B boundary all land ≥65B total" do
    for n <- [1, 32, 64, 65, 128, 4096] do
      {:ok, frame} = Frame.encode(ref_header(), :crypto.strong_rand_bytes(n))
      assert :erlang.iolist_size(frame) == @header_size + n
      assert :erlang.iolist_size(frame) >= 65
    end
  end
end
