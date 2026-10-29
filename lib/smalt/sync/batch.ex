defmodule Smalt.Sync.Batch do
  @moduledoc """
  ATH-1 batch decode: a batch body is a concatenation of `Smalt.Sync.Frame`
  frames. Integrity first — decode + integrity classification completes
  before any commit.

  Batch-fatal (corrupt-header class: `EMPTY`, `SHORT_FRAME`, `BAD_MAGIC`,
  `BAD_LEN` on any frame boundary) → the connection-level refusal face;
  nothing is committed. `BAD_CRC32` and `SEQ_REGRESSION` are per-frame
  refusals (prior admits stand; the per-client seq baseline never advances
  past a refused frame, so a later frame with seq > baseline can still
  admit).
  """

  alias Smalt.Sync.Frame

  @doc """
  Decodes a batch body into frames, enforcing per-client strict seq
  monotonicity. `last_seq` is the per-client baseline the caller reads from
  the committed store (0 when none).

  Returns `{:ok, frames}` — every frame carries either `:refusal` (typed
  code string) or no refusal (candidate for governance) — or a batch-fatal
  `{:error, {:bad_batch, code}}` (client `CodecError`-matching codes).
  """
  @spec decode(binary(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, {:bad_batch, String.t()}}
  def decode(bin, last_seq) when is_binary(bin) and is_integer(last_seq) do
    if byte_size(bin) == 0 do
      {:error, {:bad_batch, "EMPTY"}}
    else
      decode_frames(bin, last_seq, [])
    end
  end

  defp decode_frames(<<>>, _last_seq, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_frames(bin, last_seq, acc) do
    case Frame.decode(bin) do
      {:ok, frame, rest} ->
        cond do
          not frame.crc_ok ->
            decode_frames(rest, last_seq, [Map.put(frame, :refusal, "BAD_CRC32") | acc])

          frame.seq <= last_seq ->
            decode_frames(rest, last_seq, [Map.put(frame, :refusal, "SEQ_REGRESSION") | acc])

          true ->
            decode_frames(rest, max(last_seq, frame.seq), [frame | acc])
        end

      {:error, {:bad_frame, code}} ->
        {:error, {:bad_batch, code}}
    end
  end
end
