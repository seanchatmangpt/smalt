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

  # -- Payload -> XML renderer (payload maps from SqsActions) -------------------

  @doc "Render an action payload map as the action's XML envelope."
  @spec response_from_payload(String.t(), map()) :: String.t()
  def response_from_payload(action, payload) do
    response(action, result_xml(action, payload))
  end

  defp result_xml("ReceiveMessage", %{"Messages" => msgs}) when is_list(msgs) do
    Enum.map(msgs, &message_from_payload/1)
  end

  defp result_xml("ReceiveMessage", _), do: ""

  defp result_xml("SendMessageBatch", payload) when is_map(payload) do
    Enum.map(payload["Successful"] || [], fn e ->
      ["<SendMessageBatchResultEntry>", scalars_to_xml(e), "</SendMessageBatchResultEntry>"]
    end) ++
      Enum.map(payload["Failed"] || [], fn e ->
        [
          "<BatchResultErrorEntry>",
          scalars_to_xml(%{
            "Id" => escape(e["Id"]),
            "SenderFault" => if(e["SenderFault"], do: "true", else: "false")
          }),
          "<Code>",
          escape(e["Code"]),
          "</Code><Message>",
          escape(e["Message"]),
          "</Message></BatchResultErrorEntry>"
        ]
      end)
  end

  defp result_xml("DeleteMessageBatch", payload) when is_map(payload) do
    Enum.map(payload["Successful"] || [], fn e ->
      "<DeleteMessageBatchResultEntry><Id>" <> escape(e["Id"]) <> "</Id></DeleteMessageBatchResultEntry>"
    end) ++
      Enum.map(payload["Failed"] || [], fn e ->
        [
          "<BatchResultErrorEntry>",
          scalars_to_xml(%{"Id" => escape(e["Id"]), "SenderFault" => "false"}),
          "<Code>",
          escape(e["Code"]),
          "</Code><Message>",
          escape(e["Message"]),
          "</Message></BatchResultErrorEntry>"
        ]
      end)
  end

  defp result_xml("GetQueueAttributes", %{"Attributes" => attrs}) when is_map(attrs) do
    Enum.map(attrs, fn {n, v} ->
      "<Attribute><Name>" <> escape(n) <> "</Name><Value>" <> escape(v) <> "</Value></Attribute>"
    end)
  end

  defp result_xml("GetQueueAttributes", _), do: ""

  defp result_xml("ListQueues", %{"QueueUrls" => urls}) do
    Enum.map(urls, fn u -> "<QueueUrl>" <> escape(u) <> "</QueueUrl>" end)
  end

  defp result_xml("ListQueues", _), do: ""

  # CreateQueue / SendMessage / empty-payload actions: scalar fields.
  defp result_xml(_action, payload) do
    scalars_to_xml(payload)
  catch
    :padding -> ""
  end

  defp scalars_to_xml(payload) when is_map(payload) do
    payload
    |> Enum.map(fn {k, v} -> "<" <> k <> ">" <> escape(v) <> "</" <> k <> ">" end)
  end

  defp scalars_to_xml(_), do: []

  @doc "A <Message> element from a payload map."
  @spec message_from_payload(map()) :: String.t()
  def message_from_payload(m) do
    sys_attrs =
      Enum.map(m["Attributes"] || %{}, fn {n, v} ->
        "<Attribute><Name>" <> escape(n) <> "</Name><Value>" <> escape(v) <> "</Value></Attribute>"
      end)

    {msg_attr_md5, msg_attrs_xml} =
      case m["MessageAttributesRaw"] do
        nil -> {"", ""}
        [] -> {"", ""}
        kvs ->
          md5 = Smalt.Egress.Sqs.SqsMd5.attributes_md5(kvs)
          {
            "<MD5OfMessageAttributes>" <> md5 <> "</MD5OfMessageAttributes>",
            Enum.map(kvs, fn {n, v} ->
              "<MessageAttribute><Name>" <>
                escape(n) <>
                "</Name><Value>" <>
                escape(v) <>
                "</Value><DataType>String</DataType></MessageAttribute>"
          end)
          }
      end

    [
      "<Message>",
      "<MessageId>#{escape(m["MessageId"])}</MessageId>",
      "<ReceiptHandle>#{escape(m["ReceiptHandle"])}</ReceiptHandle>",
      "<MD5OfBody>#{m["MD5OfBody"]}</MD5OfBody>",
      "<Body>#{escape(m["Body"])}</Body>",
      sys_attrs,
      msg_attr_md5,
      msg_attrs_xml,
      "</Message>"
    ]
    |> IO.iodata_to_binary()
  end
end
