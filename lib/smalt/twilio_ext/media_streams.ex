defmodule Smalt.TwilioExt.MediaStreams do
  @moduledoc "Voice Media Streams websocket JSON frames: connected, start, media, mark, stop."
  def connected, do: Jason.encode!(%{"event" => "connected", "protocol" => "Call", "version" => "1.0.0"})

  def start(stream_sid, call_sid),
    do:
      Jason.encode!(%{"event" => "start", "sequenceNumber" => "1", "streamSid" => stream_sid,
        "start" => %{"streamSid" => stream_sid, "callSid" => call_sid, "tracks" => ["inbound"],
          "mediaFormat" => %{"encoding" => "audio/x-mulaw", "sampleRate" => 8000, "channels" => 1}}})

  def media(stream_sid, seq, chunk, payload) when is_binary(payload),
    do:
      Jason.encode!(%{"event" => "media", "sequenceNumber" => to_string(seq), "streamSid" => stream_sid,
        "media" => %{"track" => "inbound", "chunk" => to_string(chunk), "timestamp" => to_string(chunk * 20),
          "payload" => Base.encode64(payload)}})

  def stop(stream_sid, seq),
    do: Jason.encode!(%{"event" => "stop", "sequenceNumber" => to_string(seq), "streamSid" => stream_sid})

  @spec decode(String.t()) :: {:ok, map()} | {:error, atom()}
  def decode(frame) do
    case Jason.decode(frame) do
      {:ok, %{"event" => ev} = m} ->
        if ev in ~w(connected start media mark stop) do
          with :ok <- payload_ok(m), do: {:ok, m}
        else
          {:error, :unknown_event}
        end

      _ ->
        {:error, :bad_frame}
    end
  end

  defp payload_ok(%{"event" => "media", "media" => %{"payload" => p}}) when is_binary(p),
    do: if(match?({:ok, _}, Base.decode64(p)), do: :ok, else: {:error, :bad_payload})
  defp payload_ok(%{"event" => "media"}), do: {:error, :bad_payload}
  defp payload_ok(_), do: :ok
end
