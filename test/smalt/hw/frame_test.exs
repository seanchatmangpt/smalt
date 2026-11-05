defmodule Smalt.Hw.FrameTest do
  @moduledoc """
  C9 lane court for the streaming deframer's cons-based decode accumulator:
  byte-stuffing roundtrips on 0x7E/0x7D-saturated payloads, split-adversary
  feeding (every split point + byte-at-a-time), and mid-stream CRC resync.
  Byte-identical frame semantics with the pre-cons binary accumulator.
  """

  use ExUnit.Case, async: false

  alias Smalt.Hw.Frame

  defp saturated_payload(n) do
    for i <- 1..n do
      case rem(i, 4) do
        0 -> 0x7E
        1 -> 0x7D
        2 -> 0x7E
        _ -> rem(i * 17 + 3, 256)
      end
    end
    |> IO.iodata_to_binary()
  end

  defp feed(encoded, split) do
    encoded
    |> :binary.binsplit(split)
    |> Enum.reduce(Frame.decoder(), &Frame.push(&2, &1))
  end

  defp drain(decoder), do: {payloads, _} = Frame.take(decoder)

  describe "roundtrip" do
    test "saturated payloads at sizes 1 / 255 / 4096" do
      for n <- [1, 255, 4096] do
        payload = saturated_payload(n)
        encoded = Frame.encode(payload)
        {payloads, _} = feed(encoded, byte_size(encoded)) |> Frame.take()
        assert payloads == [payload]
      end
    end
  end

  describe "split-adversary" do
    test "every 1..n split point yields identical frames" do
      payload = saturated_payload(64)
      encoded = Frame.encode(payload)

      for split <- 1..(byte_size(encoded) - 1) do
        assert feed(encoded, split) |> Frame.take() |> elem(0) == [payload],
               "split at #{split}"
      end
    end

    test "byte-at-a-time feeding yields identical frames" do
      payload = saturated_payload(64)
      encoded = Frame.encode(payload)

      d =
        encoded
        |> :binary.binsplit(1)
        |> Enum.reduce(Frame.decoder(), &Frame.push(&2, &1))

      assert Frame.take(d) |> elem(0) == [payload]
    end

    test "multiple frames in one stream, byte-at-a-time" do
      payloads = [saturated_payload(5), saturated_payload(1), <<1, 2, 3>>]
      stream = Enum.map_join(payloads, "", &Frame.encode/1)

      d = Enum.reduce(:binary.binsplit(stream, 1), Frame.decoder(), &Frame.push(&2, &1))
      {got, d2} = Frame.take(d)
      assert got == payloads
      # drained decoder is clean: an empty frame still roundtrips after
      {p2, _} = Frame.push(d2, Frame.encode("next")) |> Frame.take()
      assert p2 == ["next"]
    end
  end

  describe "resync" do
    test "corrupt CRC mid-stream, valid frame after: only the valid frame drains" do
      good = Frame.encode("after-corruption")

      # Hand-built corrupt frame: valid structure, wrong CRC bytes.
      body = <<4::little-integer-size(16), "doomed">>
      bad = <<0x7E, body::binary, 0xDE, 0xAD, 0x7E>>

      stream = bad <> good
      {payloads, _} = Frame.push(Frame.decoder(), stream) |> Frame.take()
      assert payloads == ["after-corruption"]
    end

    test "wrong-length frame is dropped, stream resyncs on next 0x7E" do
      body = <<9::little-integer-size(16), "tiny">>
      bad = <<0x7E, body::binary, 0x00, 0x00, 0x7E>>
      good = Frame.encode("ok")

      {payloads, _} = Frame.push(Frame.decoder(), bad <> good) |> Frame.take()
      assert payloads == ["ok"]
    end
  end
end
