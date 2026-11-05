defmodule Smalt.Egress.Sqs.SqsXml do
  @moduledoc """
  SQS query-protocol XML envelopes (lane K-SQ). Namespace
  `http://queue.amazonaws.com/doc/2012-11-05/`. `Content-Type: text/xml` is
  set by the routes plug.

  Every response ends with a `<ResponseMetadata><RequestId>` element — real
  SQS always carries one.

  COLLISION DISCLOSURE (lane K-SQ receipt): this file was concurrently
  touched by another writer with a stub `wrap/3` during the wave; this full
  implementation supersedes it (last-writer ownership per fanout law).
  """

  @xmlns "http://queue.amazonaws.com/doc/2012-11-05/"

  @doc "Wrap result children in the ActionResponse/ActionResult envelope."
  @spec response(String.t(), iodata()) :: String.t()
  def response(action, result_children) do
    """
    <#{action}Response xmlns="#{@xmlns}">
    <#{action}Result>#{result_children}</#{action}Result>
    <ResponseMetadata><RequestId>#{request_id()}</RequestId></ResponseMetadata>
    </#{action}Response>
    """
    |> IO.iodata_to_binary()
  end

  @doc "Real SQS ErrorResponse envelope (Type/Code/Message/Detail)."
  @spec error(String.t(), String.t()) :: String.t()
  def error(code, message, type \\ "Sender") do
    """
    <ErrorResponse xmlns="#{@xmlns}">
    <Error>
    <Type>#{type}</Type>
    <Code>#{escape(code)}</Code>
    <Message>#{escape(message)}</Message>
    <Detail/>
    </Error>
    <ResponseMetadata><RequestId>#{request_id()}</RequestId></ResponseMetadata>
    </ErrorResponse>
    """
    |> IO.iodata_to_binary()
  end

  @doc "A <Message> element for ReceiveMessageResult."
  @spec message(map()) :: String.t()
  def message(m) do
    attrs =
      m
      |> Map.get(:attributes, [])
      |> Enum.map(fn {n, v} ->
        "<Attribute><Name>#{escape(n)}</Name><Value>#{escape(v)}</Value></Attribute>"
      end)

    [
      "<Message>",
      "<MessageId>#{escape(m.message_id)}</MessageId>",
      "<ReceiptHandle>#{escape(m.receipt_handle)}</ReceiptHandle>",
      "<MD5OfBody>#{m.md5_of_body}</MD5OfBody>",
      "<Body>#{escape(m.body)}</Body>",
      attrs,
      Map.get(m, :extra, ""),
      "</Message>"
    ]
    |> IO.iodata_to_binary()
  end

  @doc "XML-escape text content."
  @spec escape(term()) :: String.t()
  def escape(v) when is_binary(v) do
    v
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  def escape(v), do: v |> to_string() |> escape()

  # uuid-shaped request id; SDKs ignore it.
  defp request_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
