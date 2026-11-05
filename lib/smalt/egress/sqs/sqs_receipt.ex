defmodule Smalt.Egress.Sqs.SqsReceipt do
  @moduledoc """
  SQS receipt handles (lane K-SQ).

  LAW: the Service Bus dashed-UUID lock token must NEVER leak onto the SQS
  wire (falsifier: `re.fullmatch(r"[0-9a-f]{8}-...{12}", handle) is None` in
  the py court). Minted form:

      "sqs1" <> Base.url_encode64(<<md5_prefix::binary-size(4), payload::binary>>)

  payload = term_to_binary({queue, seq, lock_token, deadline_ms}).

  `decode/1` validates the checksum and shape and returns the tuple;
  full liveness validation (queue match, current-token, deadline) happens in
  `Smalt.Egress.Sqs.SqsActions` against live store state, because
  `ChangeMessageVisibility` legitimately extends `locked_until` beyond the
  mint-time deadline embedded in an old-but-still-valid handle.
  """

  @prefix "sqs1"

  @spec mint(String.t(), integer(), String.t(), integer()) :: String.t()
  def mint(queue, seq, lock_token, deadline_ms) do
    payload = :erlang.term_to_binary({queue, seq, lock_token, deadline_ms})
    <<checksum::binary-size(4), _::binary>> = :erlang.md5(payload)

    @prefix <> Base.url_encode64(<<checksum::binary-size(4), payload::binary>>)
  end

  @doc """
  Checksum-validated decode. Returns `{:ok, {queue, seq, lock_token, deadline}}`
  or `{:error, :receipt_handle_is_invalid}` (any structural failure).
  """
  @spec decode(String.t()) :: {:ok, tuple()} | {:error, :receipt_handle_is_invalid}
  def decode("sqs1" <> rest) when is_binary(rest) do
    with {:ok, bin} <- Base.url_decode64(rest),
         <<checksum::binary-size(4), payload::binary>> <- bin,
         ^checksum <- binary_part(:erlang.md5(payload), 0, 4),
         {_, _, _, _} = tuple <- :erlang.binary_to_term(payload, [:safe]) do
      {:ok, tuple}
    else
      _ -> {:error, :receipt_handle_is_invalid}
    end
  end

  def decode(_), do: {:error, :receipt_handle_is_invalid}
end
