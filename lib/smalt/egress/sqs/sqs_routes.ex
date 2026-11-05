defmodule Smalt.Egress.Sqs.SqsRoutes do
  @moduledoc """
  SQS query-protocol wire surface (lane K-SQ): the boto3/SQS REST face.

  MOUNT LINE (the egress_router.ex edit is OUTSIDE this lane's lease — the
  coordinator applies it, one line, BEFORE `plug(Smalt.Egress.ServiceBusRestRoutes)`
  at egress_router.ex:147):

      plug(Smalt.Egress.Sqs.SqsRoutes)

  The court boots the plug locally over REAL TCP (Bandit), same pattern as
  the EH-REST court.

  Face disambiguation: claims a conn only when
    - method POST, and
    - the `Authorization` header carries AWS SigV4
      (`AWS4-HMAC-SHA256 ...`) — the SQS client face no other plane uses.
  boto3 real-signs every request (SigV4), so the py court exercises this gate
  on every call. Everything else passes through un-halted.

  Protocol: `application/x-www-form-urlencoded` body, `Action=` +
  `Version=2012-11-05` (SqsQuery). Responses `text/xml` (SqsXml). Errors are
  typed SQS ErrorResponse envelopes.

  Auth note (disclosed, KD-SQ2): the SigV4 signature is NOT verified — any
  well-formed SigV4 header admits. Real AWS verifies; the emulator face
  accepts the signed shape and lets real boto3 (which cannot send unsigned)
  falsify the wire format on every request.
  """

  alias Smalt.Egress.Sqs.SqsActions
  alias Smalt.Egress.Sqs.SqsQuery
  alias Smalt.Egress.Sqs.SqsXml

  def init(opts), do: opts

  def call(conn, _opts) do
    if sqs_face?(conn) do
      handle(conn)
    else
      conn
    end
  end

  defp sqs_face?(conn) do
    conn.method == "POST" and sigv4?(Plug.Conn.get_req_header(conn, "authorization"))
  end

  defp sigv4?(["AWS4-HMAC-SHA256" <> _ | _]), do: true
  defp sigv4?(_), do: false

  # Two wire faces (KD-SQ2 note): legacy query protocol (form-urlencoded,
  # Version gate) and MODERN boto3 JSON protocol (Content-Type
  # application/x-amz-json-1.0, X-Amz-Target: AmazonSQS.<Action>). Modern
  # botocore (>=1.34) speaks JSON-with-query-mode for SQS — witnessed on the
  # wire in the wf9 court boot; the form face stays for AWS CLI/older SDKs.
  defp handle(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    cond do
      x_amz_target?(conn) ->
        params = SqsQuery.json_params(body, action_from_target(conn))

        dispatch(conn, params)

      true ->
        case SqsQuery.parse(body) do
          {:ok, params} ->
            dispatch(conn, params)

          {:error, :version} ->
            error(conn, 400, "InvalidAction", "Unsupported Version — expected 2012-11-05.")
        end
    end
  end

  defp x_amz_target?(conn) do
    Plug.Conn.get_req_header(conn, "x-amz-target") != []
  end

  defp action_from_target(conn) do
    case Plug.Conn.get_req_header(conn, "x-amz-target") do
      ["AmazonSQS." <> action | _] -> action
      [other | _] -> String.replace_prefix(other, "AmazonSQS.", "")
      [] -> nil
    end
  end

  defp dispatch(conn, params) do
    action = params["Action"]
    host = host_header(conn)
    json_face? = x_amz_target?(conn)

    result =
      try do
        run(action, host, params)
      rescue
        # Fail-closed typed envelope: an action crash must never become an
        # untyped 500 (the conn would fall through the router un-halted).
        e ->
          {:error, "InternalFailure", Exception.message(e) || "internal error"}
      end

    case result do
      {:ok, payload} ->
        if json_face? do
          json_respond(conn, 200, payload)
        else
          respond(conn, 200, SqsXml.response_from_payload(action, payload))
        end

      {:error, code, msg} ->
        if json_face? do
          json_error(conn, status_for(code), code, msg)
        else
          error(conn, status_for(code), code, msg)
        end

      _ ->
        if json_face? do
          json_error(conn, 400, "InvalidAction", "The action #{inspect(action)} is not supported.")
        else
          error(conn, 400, "InvalidAction", "The action #{inspect(action)} is not supported.")
        end
    end
  end

  # Modern-boto3 JSON face: json protocol parser expects JSON bodies; error
  # shape {"__type": code, "Message": msg}.
  defp json_respond(conn, status, payload) do
    payload = json_shape(payload)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
    |> Plug.Conn.halt()
  end

  # JSON-face shaping: message attributes ride botocore's expected shape
  # ({name => {StringValue, DataType}}) and the canonical MD5 is recomputed.
  defp json_shape(%{"Messages" => msgs} = payload) do
    msgs =
      Enum.map(msgs, fn m ->
        case m["MessageAttributesRaw"] do
          nil ->
            Map.delete(m, "MessageAttributesRaw")

          props when props == %{} ->
            Map.delete(m, "MessageAttributesRaw")

          props ->
            m
            |> Map.delete("MessageAttributesRaw")
            |> Map.put(
              "MessageAttributes",
              Map.new(props, fn {n, v} -> {n, %{"StringValue" => v, "DataType" => "String"}} end)
            )
            |> Map.put("MD5OfMessageAttributes", Smalt.Egress.Sqs.SqsMd5.attributes_md5(props))
        end
      end)

    Map.put(payload, "Messages", msgs)
  end

  defp json_shape(payload), do: payload

  defp json_error(conn, status, code, message) do
    json_respond(conn, status, %{"__type" => code, "Message" => message})
  end

  defp run("CreateQueue", h, p), do: SqsActions.create_queue(h, p)
  defp run("ListQueues", h, p), do: SqsActions.list_queues(h, p)
  defp run("GetQueueAttributes", _h, p), do: SqsActions.get_queue_attributes(nil, p)
  defp run("SendMessage", _h, p), do: SqsActions.send_message(nil, p)
  defp run("SendMessageBatch", _h, p), do: SqsActions.send_message_batch(nil, p)
  defp run("ReceiveMessage", _h, p), do: SqsActions.receive_message(nil, p)
  defp run("DeleteMessage", _h, p), do: SqsActions.delete_message(nil, p)
  defp run("DeleteMessageBatch", _h, p), do: SqsActions.delete_message_batch(nil, p)
  defp run("ChangeMessageVisibility", _h, p), do: SqsActions.change_message_visibility(nil, p)
  defp run("DeleteQueue", _h, p), do: SqsActions.delete_queue(nil, p)

  defp run(_, _, _), do: nil

  # Real-SQS status codes for the typed codes this surface emits.
  defp status_for("ReceiptHandleIsInvalid"), do: 404
  defp status_for("OverLimit"), do: 403
  defp status_for("AWS.SimpleQueueService.NonExistentQueue"), do: 400
  defp status_for("AWS.SimpleQueueService.MessageNotInflight"), do: 400
  defp status_for(_), do: 400

  # Terminal send + halt (router law: never fall through after send).
  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/xml")
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end

  defp error(conn, status, code, message), do: respond(conn, status, SqsXml.error(code, message))

  defp host_header(conn) do
    case Plug.Conn.get_req_header(conn, "host") do
      [h | _] -> h
      [] -> "localhost"
    end
  end
end
