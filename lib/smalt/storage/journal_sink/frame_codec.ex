defmodule Smalt.Storage.JournalSink.FrameCodec do
  @moduledoc """
  SJ-2 / PROD-1 journal frame codec (wire-pinned, extracted from
  `Smalt.Storage.JournalSink` along the `# --- frame codec` fence).

  Frame wire format (big-endian, one self-delimiting frame per record):

      MAGIC  "SMAL"                    4 bytes
      FrameLen u32  — bytes following the FrameLen field:
                       SeqID(8) + Ts(8) + EventType(2) + TableID(2)
                       + KeyLen(4) + Key + PayloadLen(4) + Payload + CRC32(4)
      SeqID    u64  — monotonic, sink-wide, assigned by the sink
      Ts       s64  — wall-clock milliseconds (caller-supplied or now)
      EventType u16
      TableID  u16
      KeyLen   u32, Key (KeyLen bytes)
      PayloadLen u32, Payload (PayloadLen bytes)
      CRC32    u32  — over SeqID..Payload (everything between FrameLen and CRC)
  """

  @magic "SMAL"
  @fixed 28
  @crc_len 4

  @doc "Wire magic constant (`\"SMAL\"`)."
  def frame_magic, do: @magic

  @doc "Encodes one journal frame. Returns {frame_binary, total_byte_size, seq_id}."
  def encode_frame(seq_id, ts, event_type, table_id, key, payload)
      when is_integer(seq_id) and seq_id >= 0 and is_binary(key) and is_binary(payload) do
    key_len = byte_size(key)
    payload_len = byte_size(payload)

    body =
      <<seq_id::unsigned-integer-size(64), ts::signed-integer-size(64),
        event_type::unsigned-integer-size(16), table_id::unsigned-integer-size(16),
        key_len::unsigned-integer-size(32), key::binary, payload_len::unsigned-integer-size(32),
        payload::binary>>

    crc = :erlang.crc32(body)
    frame_len = byte_size(body) + @crc_len

    frame =
      <<@magic::binary, frame_len::unsigned-integer-size(32), body::binary,
        crc::unsigned-integer-size(32)>>

    {frame, byte_size(frame), seq_id}
  end

  @doc """
  Decodes exactly one frame from `bin` (frame must start at offset 0).
  Returns {:ok, frame_map, rest_binary} or {:error, reason}.

  frame_map: %{seq_id, ts, event_type, table_id, key, payload}
  """
  def decode_frame(bin) when is_binary(bin) do
    case bin do
      <<@magic::binary, frame_len::unsigned-integer-size(32), rest::binary>> ->
        cond do
          frame_len < @fixed + @crc_len ->
            {:error, {:bad_frame_len, frame_len}}

          byte_size(rest) < frame_len ->
            {:error, :truncated}

          true ->
            body_size = frame_len - @crc_len

            <<body::binary-size(^body_size)-unit(8), crc::unsigned-integer-size(32),
              _tail::binary>> = rest

            if :erlang.crc32(body) == crc do
              finish_decode(frame_len, body, rest)
            else
              {:error, :crc_mismatch}
            end
        end

      <<bad::binary-size(4), _::binary>> ->
        {:error, {:bad_magic, bad}}

      _ ->
        {:error, :truncated}
    end
  end

  defp finish_decode(frame_len, body, rest) do
    with <<seq_id::unsigned-integer-size(64), ts::signed-integer-size(64),
           event_type::unsigned-integer-size(16), table_id::unsigned-integer-size(16),
           key_len::unsigned-integer-size(32), rest1::binary>> <- body,
         <<key::binary-size(^key_len)-unit(8), payload_len::unsigned-integer-size(32),
           rest2::binary>> <- rest1,
         <<payload::binary-size(^payload_len)-unit(8)>> <- rest2,
         true <- @fixed + key_len + payload_len + @crc_len == frame_len do
      {:ok,
       %{
         seq_id: seq_id,
         ts: ts,
         event_type: event_type,
         table_id: table_id,
         key: key,
         payload: payload
       }, binary_part(rest, frame_len, byte_size(rest) - frame_len)}
    else
      _ -> {:error, :length_mismatch}
    end
  end
end
