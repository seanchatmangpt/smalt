defmodule Smalt.Egress.Sqs.SqsActions do
  @moduledoc """
  SQS action layer (lane K-SQ): query-protocol actions over the Service Bus
  queue engine (`Smalt.Amqp.QueueStore` + `Smalt.Amqp.LockManager`) — the SAME
  engine behind the AMQP and SB-REST planes, so a message sent by boto3 is
  receivable over AMQP/SB-REST and vice versa (roundtrip court).

  Actions: CreateQueue, ListQueues, GetQueueAttributes, SendMessage,
  SendMessageBatch, ReceiveMessage (long-poll via the E1 `claim_wait`),
  DeleteMessage, DeleteMessageBatch, ChangeMessageVisibility, DeleteQueue.

  Receipt-handle law: handles are minted by `Smalt.Egress.Sqs.SqsReceipt`
  (`sqs1` + checksummed url-b64 term), never the SB dashed-UUID lock token.
  """

  alias Smalt.Amqp.LockManager
  alias Smalt.Amqp.QueueStore
  alias Smalt.Egress.Sqs.SqsMd5
  alias Smalt.Egress.Sqs.SqsQuery
  alias Smalt.Egress.Sqs.SqsReceipt
  alias Smalt.Egress.Sqs.SqsXml

  @acct "000000000000"
  @default_vt_s "30"

  # -- Queue URL helpers ---------------------------------------------------------

  @doc "QueueUrl for a queue name given the request host header (host[:port])."
  @spec queue_url(String.t(), String.t()) :: String.t()
  def queue_url(host_header, queue) do
    "http://" <> host_header <> "/" <> @acct <> "/" <> queue
  end

  @doc "Queue name from a QueueUrl param (last path segment)."
  @spec queue_name_from_url(String.t()) :: String.t() | :error
  def queue_name_from_url(url) when is_binary(url) do
    case String.split(URI.parse(url).path || "", "/", trim: true) do
      [_acct, name] -> name
      [name] -> name
      _ -> :error
    end
  end

  def queue_name_from_url(_), do: :error

  # -- CreateQueue ---------------------------------------------------------------

  @spec create_queue(String.t(), map()) :: {:ok, String.t()} | {:error, String.t(), String.t()}
  def create_queue(host, params) do
    name = params["QueueName"]

    if is_binary(name) and name != "" and String.length(name) <= 80 do
      {:ok, info} = QueueStore.ensure_queue(name)
      attrs = stored_attrs(params)
      Smalt.Store.put(:smalt_sb_queues, name, Map.put(info, :sqs_attrs, attrs))

      {:ok, %{"QueueUrl" => queue_url(host, name)}}
    else
      {:error, "MissingParameter", "The request must contain the parameter QueueName."}
    end
  end

  defp stored_attrs(params) do
    params
    |> SqsQuery.entries("Attribute")
    |> Map.new(fn e -> {e["Name"], e["Value"]} end)
    |> Map.take(~w(VisibilityTimeout DelaySeconds ReceiveMessageWaitTimeSeconds
                   MaximumMessageSize MessageRetentionPeriod RedrivePolicy))
  end

  # -- ListQueues ----------------------------------------------------------------

  @spec list_queues(String.t(), map()) :: {:ok, String.t()} | {:error, String.t(), String.t()}
  def list_queues(host, params) do
    prefix = params["QueueNamePrefix"] || ""

    urls =
      :smalt_sb_queues
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {name, _info} when is_binary(name) -> [name]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.filter(fn name ->
        String.starts_with?(name, prefix) and not String.contains?(name, "/")
      end)
      |> Enum.sort()
      |> Enum.map(&queue_url(host, &1))

    {:ok, %{"QueueUrls" => urls}}
  end

  # -- GetQueueAttributes --------------------------------------------------------

  @spec get_queue_attributes(String.t(), map()) ::
          {:ok, String.t()} | {:error, String.t(), String.t()}
  def get_queue_attributes(_host, params) do
    with {:ok, name} <- queue_from_params(params),
         {:ok, info} <- queue_exists(name) do
      requested = SqsQuery.list_param(params, "AttributeName")
      take = fn n -> is_nil(requested) or "All" in requested or n in requested end

      now = System.system_time(:millisecond)
      counts = message_counts(name, now)
      sqs_attrs = info[:sqs_attrs] || %{}
      created_s = div(info[:created] || now, 1000)

      attrs =
        Enum.concat([
          if(take.("QueueArn"), do: [{"QueueArn", arn(name)}], else: []),
          if(take.("ApproximateNumberOfMessages"),
            do: [{"ApproximateNumberOfMessages", Integer.to_string(counts.available)}],
            else: []
          ),
          if(take.("ApproximateNumberOfMessagesNotVisible"),
            do: [{"ApproximateNumberOfMessagesNotVisible", Integer.to_string(counts.not_visible)}],
            else: []
          ),
          if(take.("ApproximateNumberOfMessagesDelayed"),
            do: [{"ApproximateNumberOfMessagesDelayed", Integer.to_string(counts.delayed)}],
            else: []
          ),
          if(take.("VisibilityTimeout"),
            do: [{"VisibilityTimeout", Map.get(sqs_attrs, "VisibilityTimeout", @default_vt_s)}],
            else: []
          ),
          if(take.("DelaySeconds"),
            do: [{"DelaySeconds", Map.get(sqs_attrs, "DelaySeconds", "0")}],
            else: []
          ),
          if(take.("ReceiveMessageWaitTimeSeconds"),
            do: [{"ReceiveMessageWaitTimeSeconds", Map.get(sqs_attrs, "ReceiveMessageWaitTimeSeconds", "0")}],
            else: []
          ),
          if(take.("MaximumMessageSize"),
            do: [{"MaximumMessageSize", Map.get(sqs_attrs, "MaximumMessageSize", "262144")}],
            else: []
          ),
          if(take.("MessageRetentionPeriod"),
            do: [{"MessageRetentionPeriod", Map.get(sqs_attrs, "MessageRetentionPeriod", "345600")}],
            else: []
          ),
          if(take.("CreatedTimestamp"), do: [{"CreatedTimestamp", Integer.to_string(created_s)}], else: []),
          if(take.("LastModifiedTimestamp"),
            do: [{"LastModifiedTimestamp", Integer.to_string(created_s)}],
            else: []
          )
        ])

      {:ok, %{"Attributes" => Map.new(attrs)}}
    end
  end

  defp message_counts(name, now) do
    msgs =
      :smalt_sb_messages
      |> :ets.match_object({{name, :_}, :_})
      |> Enum.map(fn {_k, m} -> m end)

    %{
      available:
        Enum.count(msgs, fn m ->
          m.state == :available and not locked_now?(m, now)
        end),
      not_visible:
        Enum.count(msgs, fn m ->
          (m.state == :locked and locked_now?(m, now)) or m.state == :deferred
        end),
      delayed:
        Enum.count(msgs, fn m ->
          m.state == :scheduled and is_integer(m[:scheduled_enqueue_time]) and
            m[:scheduled_enqueue_time] > now
        end)
    }
  end

  defp locked_now?(%{state: :locked, locked_until: until}, now) when is_integer(until),
    do: until > now

  defp locked_now?(_, _), do: false

  defp arn(name), do: "arn:aws:sqs:us-east-1:" <> @acct <> ":" <> name

  # -- SendMessage ---------------------------------------------------------------

  @spec send_message(String.t(), map()) :: {:ok, String.t()} | {:error, String.t(), String.t()}
  def send_message(_host, params) do
    with {:ok, name} <- queue_from_params(params),
         {:ok, _} <- queue_exists(name),
         body when is_binary(body) <- params["MessageBody"] do
      now = System.system_time(:millisecond)
      delay_s = SqsQuery.int_param(params, "DelaySeconds") || delay_attr_s(name) || 0
      attrs = message_attributes(params)
      message_id = uuid()

      opts =
        [message_id: message_id]
        |> maybe_sched(now, delay_s)
        |> put_attrs(attrs)

      case QueueStore.enqueue(name, body, opts) do
        {:ok, _seq} ->
          payload = %{
            "MD5OfMessageBody" => SqsMd5.body_md5(body),
            "MessageId" => message_id
          }

          payload =
            if attrs == %{},
              do: payload,
              else: Map.put(payload, "MD5OfMessageAttributes", SqsMd5.attributes_md5(attrs))

          {:ok, payload}

        {:error, :too_large} ->
          {:error, "InvalidParameterValue", "MessageBody exceeds the maximum message size."}

        {:error, :capacity} ->
          {:error, "OverLimit", "The queue is at capacity."}

        {:error, :session_required} ->
          {:error, "InvalidParameterValue", "The queue requires a session id."}
      end
    else
      {:error, _, _} = err -> err
      _ -> {:error, "MissingParameter", "The request must contain the parameter MessageBody."}
    end
  end

  # real SQS: empty MessageBody is a SenderFault (MissingParameter)
  defp body_ok?(b), do: is_binary(b) and b != ""

  # Batch entries carry nested message attributes at
  # SendMessageBatchRequestEntry.N.MessageAttribute.M.Name/Value — a deeper
  # dotted-index level; use entries_all over the flat map via a synthetic
  # prefix remap of the flat keys.
  defp message_attributes_from_entry(e) do
    e
    |> Enum.flat_map(fn {k, v} ->
      case String.split(k, ".") do
        ["MessageAttribute", i, field] -> [{"MessageAttribute." <> i <> "." <> field, v}]
        _ -> []
      end
    end)
    |> Map.new()
    |> SqsQuery.entries_all("MessageAttribute")
    |> Map.new(fn a -> {a["Name"], a["Value"]} end)
  end

  # SQS message attributes ride app_props (String-typed face); emitted back on
  # receive when MessageAttributeNames requests them.
  defp put_attrs(opts, attrs) when attrs == %{}, do: opts
  defp put_attrs(opts, attrs), do: Keyword.put(opts, :app_props, attrs)

  defp maybe_sched(opts, _now, 0), do: opts

  defp maybe_sched(opts, now, delay_s) when is_integer(delay_s) and delay_s > 0,
    do: Keyword.put(opts, :scheduled_enqueue_time, now + delay_s * 1000)

  defp maybe_sched(opts, _now, _), do: opts

  defp delay_attr_s(name) do
    case queue_attr(name, "DelaySeconds") do
      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp message_attributes(params) do
    params
    |> SqsQuery.entries_all("MessageAttribute")
    |> Map.new(fn e -> {e["Name"], e["Value"]} end)
  end

  # -- SendMessageBatch (dotted-index entries, partial failure) -------------------

  @spec send_message_batch(String.t(), map()) ::
          {:ok, String.t()} | {:error, String.t(), String.t()}
  def send_message_batch(_host, params) do
    with {:ok, name} <- queue_from_params(params),
         {:ok, _} <- queue_exists(name) do
      entries =
        params
        |> SqsQuery.entries("SendMessageBatchRequestEntry")
        |> Enum.take(10)

      {oks, fails} =
        Enum.reduce(entries, {[], []}, fn e, {oks, fails} ->
          case batch_send_one(name, e) do
            {:ok, _id, entry} -> {[entry | oks], fails}
            {:error, id, code, msg, fault?} -> {oks, [%{"Id" => id, "SenderFault" => fault?, "Code" => code, "Message" => msg} | fails]}
          end
        end)

      {:ok, %{"Successful" => Enum.reverse(oks), "Failed" => Enum.reverse(fails)}}
    end
  end

  defp batch_send_one(name, e) do
    body = e["MessageBody"]

    if body_ok?(body) do
      now = System.system_time(:millisecond)
      delay_s = parse_int(e["DelaySeconds"]) || 0
      attrs = message_attributes_from_entry(e)
      mid = uuid()

      opts =
        [message_id: mid]
        |> maybe_sched(now, delay_s)

      case QueueStore.enqueue(name, body, opts) do
        {:ok, _} ->
          attr_md5 =
            if attrs == %{},
              do: nil,
              else: SqsMd5.attributes_md5(attrs)

          entry =
            %{"Id" => e["Id"], "MessageId" => mid, "MD5OfMessageBody" => SqsMd5.body_md5(body)}
            |> then(fn m -> if attr_md5, do: Map.put(m, "MD5OfMessageAttributes", attr_md5), else: m end)

          {:ok, e["Id"], entry}

        {:error, :too_large} ->
          {:error, e["Id"], "InvalidParameterValue", "MessageBody exceeds the size cap.", false}

        _ ->
          {:error, e["Id"], "InternalError", "The message could not be enqueued.", false}
      end
    else
      {:error, e["Id"], "MissingParameter", "The request must contain MessageBody.", true}
    end
  end



  # -- ReceiveMessage -------------------------------------------------------------

  @spec receive_message(String.t(), map()) :: {:ok, String.t()} | {:error, String.t(), String.t()}
  def receive_message(_host, params) do
    with {:ok, name} <- queue_from_params(params),
         {:ok, _} <- queue_exists(name) do
      max_msgs = (SqsQuery.int_param(params, "MaxNumberOfMessages") || 1) |> clamp(1, 10)
      vt_s = SqsQuery.int_param(params, "VisibilityTimeout")
      wait_s = (SqsQuery.int_param(params, "WaitTimeSeconds") || 0) |> clamp(0, 20)
      sys_names = SqsQuery.list_param(params, "AttributeName")
      msg_names = SqsQuery.list_param(params, "MessageAttributeNames")

      base_opts =
        [wait_ms: wait_s * 1000]
        |> maybe_lock_duration(vt_s)

      msgs = collect(name, max_msgs, base_opts)

      messages =
        msgs
        |> Enum.map(&message_payload(&1, name, sys_names, msg_names))

      {:ok, %{"Messages" => messages}}
    end
  end

  defp maybe_lock_duration(opts, nil), do: opts

  defp maybe_lock_duration(opts, vt_s) when is_integer(vt_s) and vt_s >= 0,
    do: Keyword.put(opts, :lock_duration_ms, LockManager.clamp_duration(vt_s * 1000))

  defp maybe_lock_duration(opts, _), do: opts

  # First receive long-polls (claim_wait); the remaining slots drain without
  # waiting (single long-poll per request, matching real SQS behavior).
  defp collect(_queue, 0, _opts), do: []

  defp collect(queue, remaining, opts) do
    case QueueStore.claim_wait(queue, opts) do
      {:ok, msg, lock} ->
        [{msg, lock} | collect(queue, remaining - 1, Keyword.put(opts, :wait_ms, 0))]

      :empty ->
        []
    end
  end

  defp message_payload({msg, lock}, queue, sys_names, msg_attr_names) do
    receipt = SqsReceipt.mint(queue, msg.seq, lock.lock_token, lock.locked_until)
    raw = raw_body(msg.body)

    sys_attrs = system_attrs(sys_names, msg, msg.enqueued)

    payload =
      %{
        "MessageId" => msg.message_id || lock.lock_token,
        "ReceiptHandle" => receipt,
        "MD5OfBody" => SqsMd5.body_md5(raw),
        "Body" => raw,
        "Attributes" => Map.new(sys_attrs)
      }

    if message_attributes_requested?(msg_attr_names, msg) do
      props = msg[:app_props] || %{}
      Map.put(payload, "MessageAttributesRaw", props)
    else
      payload
    end
  end

  defp system_attrs(names, msg, _enqueued) do
    all = is_nil(names) or "All" in names

    candidates = [
      {"SenderId", "AIDA" <> @acct},
      {"SentTimestamp", Integer.to_string(msg.enqueued)},
      {"ApproximateReceiveCount", Integer.to_string(msg.delivery_count)},
      {"ApproximateFirstReceiveTimestamp", Integer.to_string(msg.enqueued)}
    ]

    Enum.filter(candidates, fn {n, _} -> all or n in names end)
  end

  defp message_attributes_requested?(names, msg) do
    names != nil and msg[:app_props] != %{} and msg[:app_props] != nil and
      ("All" in names or Enum.any?(names, &Map.has_key?(msg[:app_props] || %{}, &1)))
  end

  defp raw_body(body) when is_binary(body), do: body
  defp raw_body({_kind, v}) when is_binary(v), do: v
  defp raw_body({_kind, v}), do: Jason.encode!(v)

  # -- DeleteMessage --------------------------------------------------------------

  @spec delete_message(String.t(), map()) :: {:ok, String.t()} | {:error, String.t(), String.t()}
  def delete_message(_host, params) do
    with {:ok, name} <- queue_from_params(params),
         {:ok, _} <- queue_exists(name) do
      case handle_result(name, params["ReceiptHandle"]) do
        {:ok, {q, seq, token, _until}} ->
          # Idempotent face (KD-SQ1): real SQS DeleteMessage with a stale
          # (already-consumed) handle answers success and deletes nothing.
          case QueueStore.complete(q, seq, lock_token: token) do
            _ -> {:ok, %{}}

          end

        {:error, :receipt_handle_is_invalid} ->
          {:error, "ReceiptHandleIsInvalid", "The input receipt handle is invalid."}
      end
    end
  end

  # -- DeleteMessageBatch ---------------------------------------------------------

  @spec delete_message_batch(String.t(), map()) ::
          {:ok, String.t()} | {:error, String.t(), String.t()}
  def delete_message_batch(_host, params) do
    with {:ok, name} <- queue_from_params(params),
         {:ok, _} <- queue_exists(name) do
      entries =
        params
        |> SqsQuery.entries("DeleteMessageBatchRequestEntry")
        |> Enum.take(10)

      {oks, fails} =
        Enum.reduce(entries, {[], []}, fn e, {oks, fails} ->
          case handle_result(name, e["ReceiptHandle"]) do
            {:ok, {q, seq, token, _until}} ->
              _ = QueueStore.complete(q, seq, lock_token: token)

              {[%{"Id" => e["Id"]} | oks], fails}

            {:error, :receipt_handle_is_invalid} ->
              {oks, [error_entry(e["Id"], "ReceiptHandleIsInvalid", "The input receipt handle is invalid.", false) | fails]}
          end
        end)

      {:ok,
       %{
         "Successful" => Enum.reverse(oks),
         "Failed" => Enum.reverse(fails)
       }}
    end
  end

  # -- ChangeMessageVisibility -----------------------------------------------------

  @spec change_message_visibility(String.t(), map()) ::
          {:ok, String.t()} | {:error, String.t(), String.t()}
  def change_message_visibility(_host, params) do
    with {:ok, name} <- queue_from_params(params),
         {:ok, _} <- queue_exists(name),
         vt when is_integer(vt) and vt >= 0 and vt <= 43_200 <- SqsQuery.int_param(params, "VisibilityTimeout") do
      case handle_result(name, params["ReceiptHandle"]) do
        {:ok, {q, seq, token, _until}} ->
          if vt == 0 do
            case QueueStore.release(q, seq, lock_token: token) do
              :ok -> {:ok, %{}}
              {:error, :lock_lost} -> {:ok, %{}}
              :error -> {:error, "ReceiptHandleIsInvalid", "The input receipt handle is invalid."}
            end
          else
            case LockManager.renew(token, System.system_time(:millisecond), duration_ms: vt * 1000) do
              {:ok, _} ->
                {:ok, %{}}

              {:error, :not_found} ->
                {:error, "ReceiptHandleIsInvalid", "The input receipt handle is invalid."}

              {:error, :lock_lost} ->
                {:error, "AWS.SimpleQueueService.MessageNotInflight",
                 "The message is not in flight (lock expired)."}
            end
          end

        {:error, :receipt_handle_is_invalid} ->
          {:error, "ReceiptHandleIsInvalid", "The input receipt handle is invalid."}
      end
    else
      {:error, _, _} = err -> err
      _ -> {:error, "MissingParameter", "The request must contain the parameter VisibilityTimeout."}
    end
  end

  # -- DeleteQueue ----------------------------------------------------------------

  @spec delete_queue(String.t(), map()) :: {:ok, String.t()} | {:error, String.t(), String.t()}
  def delete_queue(_host, params) do
    with {:ok, name} <- queue_from_params(params),
         {:ok, _} <- queue_exists(name) do
      {:ok, _} = QueueStore.purge_queue(name)
      Smalt.Store.delete(:smalt_sb_queues, name)
      {:ok, %{}}
    end
  end

  # -- Shared internals -------------------------------------------------------------

  defp queue_from_params(params) do
    case queue_name_from_url(params["QueueUrl"]) do
      name when is_binary(name) -> {:ok, name}
      _ -> {:error, "MissingParameter", "The request must contain the parameter QueueUrl."}
    end
  end

  defp queue_exists(name) do
    case Smalt.Store.get(:smalt_sb_queues, name) do
      {:ok, info} -> {:ok, info}
      :error -> {:error, "AWS.SimpleQueueService.NonExistentQueue", "The specified queue does not exist for this wsdl version."}
    end
  end

  defp queue_attr(name, key) do
    case Smalt.Store.get(:smalt_sb_queues, name) do
      {:ok, info} -> (info[:sqs_attrs] || %{})[key]
      :error -> nil
    end
  end

  # Full liveness validation of a receipt handle against live store state:
  # checksum/shape (decode), queue match, current stored token, unexpired lock.
  defp handle_result(queue, handle) when is_binary(handle) do
    with {:ok, {tq, seq, token, _deadline}} <- SqsReceipt.decode(handle),
         :ok <- if(tq == queue, do: :ok, else: {:error, :receipt_handle_is_invalid}),
         {:ok, m} <- Smalt.Store.get(:smalt_sb_messages, {queue, seq}),
         %{} = m when m.lock_token == token <- m,
         {:ok, lock} <- LockManager.get(token),
         :ok <- if(lock.locked_until > System.system_time(:millisecond), do: :ok, else: {:error, :receipt_handle_is_invalid}) do
      {:ok, {queue, seq, token, lock.locked_until}}
    else
      _ -> {:error, :receipt_handle_is_invalid}
    end
  end

  defp handle_result(_, _), do: {:error, :receipt_handle_is_invalid}

  defp error_entry(id, code, msg, sender_fault?) do
    "<BatchResultErrorEntry><Id>" <>
      SqsXml.escape(id) <>
      "</Id><SenderFault>" <>
      (if sender_fault?, do: "true", else: "false") <>
      "</SenderFault><Code>" <>
      SqsXml.escape(code) <>
      "</Code><Message>" <> SqsXml.escape(msg) <> "</Message></BatchResultErrorEntry>"
  end

  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
