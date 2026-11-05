defmodule Smalt.PubSubGrpc.WireTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Smalt.PubSubGrpc.Wire

  doctest Smalt.PubSubGrpc.Wire

  describe "varint" do
    test "encode/decode roundtrip" do
      for n <- [0, 1, 127, 128, 300, 16_383, 16_384, 1 <<< 20, 1 <<< 35, (1 <<< 63) - 1] do
        assert {:ok, ^n, <<>>} = n |> Wire.encode_varint() |> Wire.decode_varint()
      end
    end

    test "multi-byte layout matches known protobuf bytes" do
      assert Wire.encode_varint(300) == <<0xAC, 0x02>>
      assert Wire.encode_varint(1) == <<0x01>>
      assert Wire.encode_varint(127) == <<0x7F>>
      assert Wire.encode_varint(128) == <<0x80, 0x01>>
    end

    test "truncated varint is typed refusal" do
      assert {:error, :bad_varint} = Wire.decode_varint(<<>>)
      assert {:error, :bad_varint} = Wire.decode_varint(<<0x80>>)
      assert {:error, :bad_varint} = Wire.decode_varint(<<0x80, 0x80, 0x80>>)
    end
  end

  describe "PubsubMessage" do
    test "encode/decode roundtrip with all fields" do
      msg = %{
        data: <<1, 2, 3, 0xFF>>,
        attributes: %{"a" => "1", "b" => "2"},
        message_id: "m-123",
        publish_time: {1_700_000_000, 500},
        ordering_key: "k1"
      }

      bin = Wire.encode_pubsub_message(msg)
      assert {:ok, decoded, <<>>} = Wire.decode_pubsub_message(bin)

      assert decoded.data == msg.data
      assert decoded.attributes == %{"a" => "1", "b" => "2"}
      assert decoded.message_id == "m-123"
      assert decoded.publish_time == {1_700_000_000, 500}
      assert decoded.ordering_key == "k1"
    end

    test "empty message encodes data field explicitly, decodes to defaults" do
      {:ok, m, <<>>} = %{data: <<>>} |> Wire.encode_pubsub_message() |> Wire.decode_pubsub_message()
      assert m.data == <<>>
      assert m.attributes == %{}
    end

    test "unknown fields skipped by wire type" do
      base = Wire.encode_pubsub_message(%{data: "x"})

      unknown_varint = <<encode_tag(99, 0)::binary, 42::size(8)>>
      unknown_len = <<encode_tag(98, 2)::binary, 3::size(8), "abc"::binary>>
      unknown_64 = <<encode_tag(97, 1)::binary, 0::size(64)>>
      unknown_32 = <<encode_tag(96, 5)::binary, 0::size(32)>>

      blob = IO.iodata_to_binary([base, unknown_varint, unknown_len, unknown_64, unknown_32])
      assert {:ok, m, <<>>} = Wire.decode_pubsub_message(blob)
      assert m.data == "x"
    end

    test "truncated length-delimited body is typed refusal" do
      # field 1 tag, length 5, only 2 bytes present
      bad = <<0x0A, 5, "ab">>
      assert {:error, :bad_varint} = Wire.decode_pubsub_message(bad)
    end
  end

  describe "PublishRequest/Response" do
    test "roundtrip" do
      msgs = [%{data: "a", attributes: %{"k" => "v"}}, %{data: "b"}]
      bin = Wire.encode_publish_request("projects/p/topics/t", msgs)
      assert {:ok, req, <<>>} = Wire.decode_publish_request(bin)
      assert req.topic == "projects/p/topics/t"
      assert length(req.messages) == 2
      assert hd(req.messages).attributes == %{"k" => "v"}

      ids = ["i1", "i2", "i3"]
      resp = Wire.encode_publish_response(ids)
      assert {:ok, ^ids} = Wire.decode_publish_response(resp)
    end
  end

  describe "PullRequest/Response" do
    test "roundtrip with return_immediately" do
      bin = Wire.encode_pull_request("projects/p/subscriptions/s", 10, true)
      assert {:ok, req} = Wire.decode_pull_request(bin)
      assert req.subscription == "projects/p/subscriptions/s"
      assert req.max_messages == 10
      assert req.return_immediately == true
    end

    test "return_immediately omitted when false" do
      bin = Wire.encode_pull_request("s", 5, false)
      refute bin =~ <<0x18>>
      assert {:ok, req} = Wire.decode_pull_request(bin)
      assert req.return_immediately == false
    end

    test "pull response roundtrip preserves ack_id and message bytes" do
      received = [
        %{ack_id: "ack-1", message: %{data: <<9, 9>>, attributes: %{"x" => "y"}, message_id: "m1"}},
        %{ack_id: "ack-2", message: %{data: "", attributes: %{}, message_id: "m2"}}
      ]

      bin = Wire.encode_pull_response(received)
      assert {:ok, decoded} = Wire.decode_pull_response(bin)
      assert length(decoded) == 2

      [first, second] = decoded
      assert first.ack_id == "ack-1"
      assert first.message.data == <<9, 9>>
      assert first.message.attributes == %{"x" => "y"}
      assert second.message.data == ""
      assert second.message.message_id == "m2"
    end
  end

  describe "Acknowledge/ModifyAckDeadline" do
    test "acknowledge roundtrip" do
      bin = Wire.encode_acknowledge_request("sub-1", ["a", "b"])
      assert {:ok, req} = Wire.decode_acknowledge_request(bin)
      assert req.subscription == "sub-1"
      assert req.ack_ids == ["a", "b"]
    end

    test "modify ack deadline roundtrip; deadline 0 is nack semantics" do
      bin = Wire.encode_modify_ack_deadline_request("sub-1", ["z"], 0)
      assert {:ok, req} = Wire.decode_modify_ack_deadline_request(bin)
      assert req.ack_deadline_seconds == 0
      assert req.ack_ids == ["z"]
    end
  end

  defp encode_tag(field, wt), do: Wire.encode_varint(Bitwise.bsl(field, 3) + wt)
end
