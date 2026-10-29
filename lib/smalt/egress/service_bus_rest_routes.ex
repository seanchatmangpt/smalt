defmodule Smalt.Egress.ServiceBusRestRoutes do
  @moduledoc """
  SB-REST lane: the Microsoft Service Bus REST data-plane wire surface
  (send / receive / settle over HTTP), mounted on the egress router BEFORE the
  Azure Queue Storage plane — the two share the `/{account}/{queue}/messages`
  path shape, and the disambiguator is the auth face: Service Bus clients carry
  a `SharedAccessSignature` (header `Authorization` or
  `ServiceBusAuthorization`); Queue Storage clients carry `SharedKey`.

  Wire contract (real-Azure shapes):

    POST   /{ns}/{queue}/messages                    send (201, empty)
    POST   /{ns}/{queue}/messages/head?timeout=      peek-lock receive (200 / 204 empty)
    DELETE /{ns}/{queue}/messages/head               receive-and-delete (200 / 204 empty)
    DELETE /{ns}/{queue}/messages/{seq}/{locktoken}  complete (200)
    PUT    /{ns}/{queue}/messages/{seq}/{locktoken}  unlock / abandon (200)
    POST   /{seq}/{locktoken} renew form             renew lock (200)

  - Auth: `SharedAccessSignature` verified by `Smalt.Amqp.SasVerifier` — the
    same verifier the AMQP CBS plane uses, one truth for SAS (KD-S5
    host-normalized audiences). Typed 401 envelope on a bad SAS.
  - `api-version` query param tolerated (ignored).
  - `BrokerProperties` header (JSON): request side maps MessageId, SessionId,
    PartitionKey, ViaPartitionKey, Label, CorrelationId and
    ScheduledEnqueueTimeUtc onto the store enqueue opts; response side emits
    MessageId / SequenceNumber / DeliveryCount / LockToken / SessionId /
    EnqueuedTimeUtc / LockedUntilUtc.
  - `x-ms-brokered-encoding`: request value `application/atom+xml` (or the
    bare `application/xml`) is the documented AtomPub encoding and is accepted;
    any other non-empty value is a typed 400 InvalidBrokeredEncoding. Receive
    responses emit `x-ms-brokered-encoding: application/atom+xml`.
  - Namespace segment: the emulator serves a single namespace, so the leading
    segment is tolerated-but-ignored.
  """

  alias Smalt.Amqp.LockManager
  alias Smalt.Amqp.QueueStore
  alias Smalt.Amqp.SasVerifier

  # Dashed-UUID lock token (the store-keyed form `LockManager.new_token/0`
  # mints; the URI carries this form directly).
  @lock_re ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # x-ms-brokered-encoding values accepted on send. AtomPub is the documented
  # REST face; the bare application/xml form is tolerated as the same encoding.
  @accepted_encodings ~w(application/atom+xml application/xml)

  @type conn :: Plug.Conn.t()

  @doc "Plug entry: claims only Service-Bus-flavored `/{ns}/{q}/messages...` shapes."
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def init(opts), do: opts

  def call(conn, _opts) do
    case route(conn.method, conn.path_info) do
      nil -> conn
      arm -> run(conn, arm)
    end
  end

  @doc false
  def route("POST", [_ns, _q, "messages"]), do: {:send, nil}
  def route("POST", [_, q, "messages", "head"]), do: {:receive, q, :peek_lock}
  def route("DELETE", [_, q, "messages", "head"]), do: {:receive, q, :receive_and_delete}

  def route("DELETE", [_, q, "messages", seq, t]), do: {:settle, q, :complete, seq, t}
  def route("PUT", [_, q, "messages", seq, t]), do: {:settle, q, :unlock, seq, t}
  def route("POST", [_, q, "messages", seq, t]), do: {:settle, q, :renew, seq, t}

  # Everything else — including the Azure Queue Storage `SharedKey` face —
  # passes through UNCHANGED for the downstream planes.
  def route(_, _), do: nil

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  defp run(conn, {:send, _} = arm) do
    if sb_auth_face?(conn) do
      authorized(conn, fn -> send_message(conn, arm) end)
    else
      conn
    end
  end

  defp run(conn, arm) do
    if sb_auth_face?(conn) do
      authorized(conn, fn -> handle(conn, arm) end)
    else
      conn
    end
  end

  # ---------------------------------------------------------------------------
  # Auth
  # ---------------------------------------------------------------------------

  defp sb_auth_face?(conn) do
    Plug.Conn.get_req_header(conn, "servicebusauthorization") != [] or
      sas?(Plug.Conn.get_req_header(conn, "authorization"))
  end

  defp sas?(["SharedAccessSignature " <> _ | _]), do: true
  defp sas?(_), do: false

  defp authorized(conn, fun) do
    token =
      case Plug.Conn.get_req_header(conn, "servicebusauthorization") do
        [] -> conn |> Plug.Conn.get_req_header("authorization") |> List.first()
        [v | _] -> v
      end

    if is_binary(token) do
      case SasVerifier.verify(token) do
        {:ok, _claims} ->
          fun.()

        {:error, {status, desc}} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.put_resp_header("www-authenticate", "SharedAccessSignature")
          |> respond(status, Jason.encode!(%{error: %{code: desc, message: desc}}))
      end
    else
      respond(conn, 401, Jason.encode!(%{error: %{code: "INVALID_LOCAL_SAS", message: "missing SAS token"}}))
    end
  end

  # ---------------------------------------------------------------------------
  # Send: POST /{ns}/{q}/messages
  # ---------------------------------------------------------------------------

  defp send_message(conn, _arm) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case check_brokered_encoding(conn) do
      :ok ->
        opts = enqueue_opts(conn)

        case QueueStore.enqueue(entity_name(conn), body, opts) do
          {:ok, _seq} ->
            conn
            |> Plug.Conn.put_resp_header("x-ms-brokered-encoding", encoding_out(conn))
            |> respond(201, "")

          {:error, :messaging_entity_not_found} ->
            sb_error(conn, 404, "MessagingEntityNotFound", "The entity could not be found.")

          {:error, :session_required} ->
            sb_error(conn, 400, "SessionRequired", "The queue requires a SessionId.")

          {:error, :too_large} ->
            sb_error(conn, 413, "MessageTooLarge", "The message body exceeds the size cap.")

          {:error, :capacity} ->
            sb_error(conn, 410, "QueueCapacityReached", "The queue is at capacity.")
        end

      {:error, resp} ->
        resp
    end
  end

  defp check_brokered_encoding(conn) do
    case Plug.Conn.get_req_header(conn, "x-ms-brokered-encoding") do
      [] ->
        :ok

      [v | _] ->
        if v in @accepted_encodings do
          :ok
        else
          {:error,
           sb_error(conn, 400, "InvalidBrokeredEncoding",
             "x-ms-brokered-encoding #{inspect(v)} is not a supported wire encoding."
           )}
        end
    end
  end

  defp encoding_out(conn) do
    case Plug.Conn.get_req_header(conn, "x-ms-brokered-encoding") do
      [v | _] -> v
      [] -> "application/atom+xml"
    end
  end

  # BrokerProperties (JSON header) -> store enqueue opts.
  defp enqueue_opts(conn) do
    case parse_broker_properties(conn) do
      {:ok, bp} when is_map(bp) -> bp_to_opts(bp)
      _ -> []
    end
  end

  defp parse_broker_properties(conn) do
    case Plug.Conn.get_req_header(conn, "brokerproperties") do
      [raw | _] ->
        case Jason.decode(raw) do
          {:ok, %{} = bp} -> {:ok, bp}
          _ -> :error
        end

      [] ->
        {:ok, %{}}
    end
  end

  defp bp_to_opts(bp) do
    base = [
      message_id: bp["MessageId"],
      session_id: bp["SessionId"],
      scheduled_enqueue_time: scheduled_ms(bp["ScheduledEnqueueTimeUtc"])
    ]

    base
    |> Keyword.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.put(:annotations, annotations(bp))
    |> Keyword.put(:app_props, app_props(bp))
  end

  defp annotations(bp) do
    %{}
    |> maybe_put("x-opt-partition-key", bp["PartitionKey"])
    |> maybe_put("x-opt-via-partition-key", bp["ViaPartitionKey"])
  end

  defp app_props(bp) do
    %{}
    |> maybe_put("label", bp["Label"])
    |> maybe_put("correlation-id", bp["CorrelationId"])
    |> maybe_put("reply-to", bp["ReplyTo"])
    |> maybe_put("to", bp["To"])
  end

  defp maybe_put(m, _k, nil), do: m
  defp maybe_put(m, k, v), do: Map.put(m, k, v)

  defp scheduled_ms(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp scheduled_ms(_), do: nil

  defp entity_name(conn) do
    [_ns, q, _messages] = conn.path_info
    q
  end

  # ---------------------------------------------------------------------------
  # Receive: POST (peek-lock) / DELETE (receive-and-delete) .../messages/head
  # ---------------------------------------------------------------------------

  defp handle(conn, {:receive, queue, mode}) do
    case QueueStore.queue_info(queue) do
      {:ok, _info} ->
        case QueueStore.dequeue_matching(queue) do
          {:ok, msg, lock} ->
            if mode == :receive_and_delete do
              :ok = QueueStore.complete(queue, msg.seq)
              deliver(conn, msg, nil)
            else
              deliver(conn, msg, lock)
            end

          :empty ->
            respond(conn, 204, "")
        end

      :error ->
        sb_error(conn, 404, "MessagingEntityNotFound", "The entity could not be found.")
    end
  end

  defp handle(conn, {:settle, queue, action, seq, token}) do
    if Regex.match?(@lock_re, token) do
      case Integer.parse(seq) do
        {seq, ""} -> settle(conn, queue, action, seq, token)
        _ -> sb_error(conn, 400, "InvalidLockToken", "Malformed sequence number.")
      end
    else
      sb_error(conn, 400, "InvalidLockToken", "Malformed lock token.")
    end
  end

  defp deliver(conn, msg, lock) do
    props =
      %{
        "MessageId" => msg.message_id,
        "SequenceNumber" => msg.seq,
        "DeliveryCount" => msg.delivery_count,
        "EnqueuedTimeUtc" => format_iso(msg.enqueued)
      }
      |> maybe_put("LockToken", lock && lock.lock_token)
      |> maybe_put("SessionId", msg.session_id)
      |> maybe_put("LockedUntilUtc", lock && format_iso(lock.locked_until))

    conn =
      conn
      |> Plug.Conn.put_resp_header("brokerproperties", Jason.encode!(props))
      |> Plug.Conn.put_resp_header("x-ms-brokered-encoding", "application/atom+xml")

    conn =
      if lock do
        Plug.Conn.put_resp_header(
          conn,
          "location",
          "/#{ns_segment(conn)}/#{msg.queue}/messages/#{msg.seq}/#{lock.lock_token}"
        )
      else
        conn
      end

    respond(conn, 200, body_out(msg))
  end

  # AMQP-tagged body sections ({:body_data | :body_amqp_value, v}) unwrap to
  # the section value; binaries pass as-is.
  defp body_out(%{body: {kind, v}}) when kind in [:body_data, :body_amqp_value],
    do: body_value(v)

  defp body_out(%{body: b}) when is_binary(b), do: b

  defp body_value(v) when is_binary(v), do: v
  defp body_value(v), do: Jason.encode!(v)

  defp format_iso(ms) when is_integer(ms) do
    DateTime.from_unix!(ms, :millisecond)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_iso(_), do: nil

  defp ns_segment(conn) do
    case conn.path_info do
      [ns | _] -> ns
      _ -> "ns"
    end
  end

  # ---------------------------------------------------------------------------
  # Settlement: DELETE (complete) / PUT (unlock) / POST (renew) on lock URI
  # ---------------------------------------------------------------------------

  defp settle(conn, queue, :complete, seq, token) do
    case QueueStore.complete(queue, seq, lock_token: token) do
      :ok -> respond(conn, 200, "")
      {:error, :lock_lost} -> sb_error(conn, 410, "MessageLockLost", "The lock has expired.")
    end
  end

  defp settle(conn, queue, :unlock, seq, token) do
    case QueueStore.release(queue, seq, lock_token: token) do
      :ok -> respond(conn, 200, "")
      {:error, :lock_lost} -> sb_error(conn, 410, "MessageLockLost", "The lock has expired.")
      {:error, :capacity} -> sb_error(conn, 410, "MessageLockLost", "Abandon deadlettered the message.")
    end
  end

  defp settle(conn, _queue, :renew, _seq, token) do
    case LockManager.renew(token, System.system_time(:millisecond)) do
      {:ok, _lock} -> respond(conn, 200, "")
      {:error, :not_found} -> sb_error(conn, 404, "MessageLockLost", "Unknown lock token.")
      {:error, :lock_lost} -> sb_error(conn, 410, "MessageLockLost", "The lock has expired.")
    end
  end

  # ---------------------------------------------------------------------------
  # Shared error envelope
  # ---------------------------------------------------------------------------

  # Terminal send + halt: the router's own planes halt after sending (the
  # conn previously fell through to the queue-storage/blob planes and their
  # put_resp_header raised AlreadySentError — same class as the router's
  # sub-router double-send finding). Halt stops the plug pipeline.
  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end

  defp sb_error(conn, status, code, message) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> respond(status, Jason.encode!(%{error: %{code: code, message: message}}))
  end
end
