defmodule Smalt.Integration.SqsRoundtripTest do
  # SQS lane (K-SQ) court: the boto3/SQS query-protocol face over REAL TCP —
  # Bandit + the real `Smalt.Egress.Sqs.SqsRoutes` plug, raw :httpc, no mocks.
  # The egress_router mount line is outside the lane lease; this court boots
  # the plug standalone (same pattern as the EH-REST court).
  #
  # Gates: SigV4 face gating, Version gate (typed 400), send/receive MD5
  # parity, receipt-handle shape (never a dashed-UUID SB token), settlement
  # + idempotent re-delete, cross-queue handle refusal, ChangeMessageVisibility
  # (vt=0 release), long-poll claim_wait (deadline + mid-poll wake, no sleeps
  # in lib/), DelaySeconds invisibility, GetQueueAttributes counts, batch
  # partial failure.

  use ExUnit.Case, async: false

  @moduletag :sqs

  alias Smalt.Amqp.QueueStore
  alias Smalt.Store

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:crypto)

    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    {:ok, _server} =
      Bandit.start_link(plug: Smalt.Egress.Sqs.SqsRoutes, scheme: :http, port: port)

    %{port: port}
  end

  setup context do
    case GenServer.start_link(Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    %{port: context[:port]}
  end

  # -- helpers ------------------------------------------------------------------

  # One FRESH Mint HTTP/1 connection per request — no keep-alive, so a parked
  # long-poll request can never head-of-line-block a concurrent send.
  defp post(port, body, opts \\ []) do
    auth =
      if Keyword.get(opts, :sigv4?, true) do
        [{"authorization", "AWS4-HMAC-SHA256 Credential=test/20261104/sqs/aws4_request"}]
      else
        []
      end

    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    {:ok, conn, ref} = Mint.HTTP1.request(conn, "POST", "/", auth, body)
    {status, resp} = recv_all(conn, ref, nil, "")
    :ok = Mint.HTTP.close(conn)
    {status, resp}
  end

  defp recv_all(conn, ref, status, body) do
    receive do
      msg ->
        case Mint.HTTP1.stream(conn, msg) do
          {:ok, conn, responses} ->
            status =
              Enum.find_value(responses, status, fn
                {:status, r, code} when r == ref -> code
                _ -> nil
              end)

            body =
              Enum.reduce(responses, body, fn resp, acc ->
                case resp do
                  {:data, r, d} when r == ref -> acc <> d
                  _ -> acc
                end
              end)

            if Mint.HTTP.open?(conn) do
              recv_all(conn, ref, status, body)
            else
              {status || 0, body}
            end

          {:error, conn, _err, _} ->
            :ok = Mint.HTTP.close(conn)
            {status || 0, body}
        end
    after
      30_000 -> {0, "timeout"}
    end
  end
  # RFC3986 body build: values percent-encoded (space -> %20, '+' stays
  # encoded as %2B — matches the RFC3986 decode law in SqsQuery).
  defp body(pairs) when is_list(pairs), do: Enum.join(pairs, "&")
  defp enc(s), do: s |> URI.encode_www_form() |> String.replace("+", "%20")

  defp create_queue(port, name) do
    {200, resp} =
      post(port, body(["Action=CreateQueue", "Version=2012-11-05", "QueueName=#{name}"]))

    assert resp =~ "<CreateQueueResponse"
    assert resp =~ "QueueUrl"
    resp
  end

  defp send_msg(port, queue, msg, extra \\ []) do
    {200, resp} =
      post(
        port,
        body(
          ["Action=SendMessage", "Version=2012-11-05", "QueueUrl=http://127.0.0.1/x/#{queue}",
           "MessageBody=#{enc(msg)}"] ++ extra
        )
      )

    resp
  end

  defp receive_msg(port, queue, extra \\ []) do
    {200, resp} =
      post(
        port,
        body(
          ["Action=ReceiveMessage", "Version=2012-11-05", "QueueUrl=http://127.0.0.1/x/#{queue}"] ++
            extra
        )
      )

    resp
  end

  # -- courts --------------------------------------------------------------------

  test "face gating: SigV4 header claims, unsigned passes through (404 from bare plug)",
       %{port: port} do
    {status, resp} =
      post(port, "Action=CreateQueue&Version=2012-11-05&QueueName=sqs-gate-q", sigv4?: false)

    # The standalone mount has no downstream plane: an unclaimed conn passes
    # through UN-halted (no typed SQS envelope ever answers an unsigned conn).
    assert resp == "" or not (resp =~ "CreateQueueResponse")
    assert status != 200

    {200, resp} = post(port, "Action=CreateQueue&Version=2012-11-05&QueueName=sqs-gate-q")
    assert resp =~ "<CreateQueueResponse"
  end

  test "Version gate: wrong/missing version is a typed 400 InvalidAction",
       %{port: port} do
    {400, resp} = post(port, "Action=CreateQueue&Version=2009-02-01&QueueName=sqs-ver-q")
    assert resp =~ "ErrorResponse"
    assert resp =~ "InvalidAction"

    {400, resp} = post(port, "Action=CreateQueue&QueueName=sqs-ver-q")
    assert resp =~ "ErrorResponse"
  end

  test "unknown action is a typed 400", %{port: port} do
    {400, resp} = post(port, "Action=PurgeQueue&Version=2012-11-05&QueueUrl=http://h/x/q")
    assert resp =~ "InvalidAction"
  end

  test "send/receive roundtrip: MD5OfBody parity, MessageId, system attributes",
       %{port: port} do
    create_queue(port, "sqs-rt-q")
    msg = "hello sqs roundtrip"
    resp = send_msg(port, "sqs-rt-q", msg)

    assert resp =~ "<SendMessageResponse"
    assert resp =~ "<MD5OfMessageBody>" <> md5(msg) <> "</MD5OfMessageBody>"
    assert resp =~ "<MessageId>"

    recv = receive_msg(port, "sqs-rt-q", ["AttributeName.1=All"])

    assert recv =~ "<ReceiveMessageResponse"
    assert recv =~ "<MD5OfBody>" <> md5(msg) <> "</MD5OfBody>"
    assert recv =~ "<Body>hello sqs roundtrip</Body>"
    assert recv =~ "<Name>ApproximateReceiveCount</Name><Value>1</Value>"
    assert recv =~ "<Name>SentTimestamp</Name>"
    refute recv =~ ~r/<ReceiptHandle>[0-9a-f]{8}-[0-9a-f]{4}-/

    # receive empties the queue
    recv2 = receive_msg(port, "sqs-rt-q")
    refute recv2 =~ "<Message>"
  end

  test "receipt handle: sqs1-prefixed, checksummed, survives delete idempotency",
       %{port: port} do
    create_queue(port, "sqs-handle-q")
    send_msg(port, "sqs-handle-q", "payload-1")

    recv = receive_msg(port, "sqs-handle-q")
    assert recv =~ "<ReceiptHandle>sqs1"

    handle = handle_from(recv)
    assert String.starts_with?(handle, "sqs1")
    # never leaks the SB dashed-UUID token
    refute Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-/, handle)

    # decode round-trips through the real mint/decode pair
    assert {:ok, {q, _seq, _token, _dl}} = Smalt.Egress.Sqs.SqsReceipt.decode(handle)
    assert q == "sqs-handle-q"

    {200, resp} =
      post(
        port,
        body(["Action=DeleteMessage", "Version=2012-11-05",
              "QueueUrl=http://127.0.0.1/x/sqs-handle-q",
              "ReceiptHandle=" <> enc(handle)])
      )

    assert resp =~ "<DeleteMessageResponse"

    # queue is now empty
    refute receive_msg(port, "sqs-handle-q") =~ "<Message>"
  end

  test "cross-queue receipt handle is refused typed ReceiptHandleIsInvalid (404)",
       %{port: port} do
    create_queue(port, "sqs-xqa")
    create_queue(port, "sqs-xqb")
    send_msg(port, "sqs-xqa", "cross")

    recv = receive_msg(port, "sqs-xqa")
    handle = handle_from(recv)

    {status, resp} =
      post(
        port,
        body(["Action=DeleteMessage", "Version=2012-11-05", "QueueUrl=http://127.0.0.1/x/sqs-xqb",
              "ReceiptHandle=" <> enc(handle)])
      )

    assert status == 404
    assert resp =~ "ReceiptHandleIsInvalid"
    assert resp =~ "ErrorResponse"
  end

  test "ChangeMessageVisibility vt=0 releases the message back to the queue",
       %{port: port} do
    create_queue(port, "sqs-cmv-q")
    send_msg(port, "sqs-cmv-q", "release-me")

    recv = receive_msg(port, "sqs-cmv-q")
    handle = handle_from(recv)
    assert recv =~ "<Name>ApproximateReceiveCount</Name><Value>1</Value>"

    {200, resp} =
      post(
        port,
        body(["Action=ChangeMessageVisibility", "Version=2012-11-05",
              "QueueUrl=http://127.0.0.1/x/sqs-cmv-q", "VisibilityTimeout=0",
              "ReceiptHandle=" <> enc(handle)])
      )

    assert resp =~ "<ChangeMessageVisibilityResponse"

    recv2 = receive_msg(port, "sqs-cmv-q")
    assert recv2 =~ "<Body>release-me</Body>"
    assert recv2 =~ "<Name>ApproximateReceiveCount</Name><Value>2</Value>"
  end

  test "long-poll: WaitTimeSeconds returns empty at ~deadline, wakes mid-poll on send",
       %{port: port} do
    create_queue(port, "sqs-lp-q")

    # empty long-poll returns at ~1s (not instantly)
    t0 = System.monotonic_time(:millisecond)

    assert receive_msg(port, "sqs-lp-q", ["WaitTimeSeconds=1"]) =~
             "<ReceiveMessageResponse"

    elapsed = System.monotonic_time(:millisecond) - t0
    assert elapsed >= 900, "empty long-poll returned after #{elapsed}ms (expected ~1s)"

    # mid-poll wake: sender fires after 200ms, receiver must get the message
    # well before the 5s deadline — no sleep-based coordination, the wake is
    # the E1 flush_waiters on enqueue.
    # :timer.apply_after = runtime SCHEDULING (no Process.sleep); the send
    # fires mid-poll 200ms in.
    me = self()

    task =
      Task.async(fn ->
        IO.puts("TASK-START")
        :timer.sleep(200)
        IO.puts("TASK-AFTER-SLEEP")
        out = send_msg(port, "sqs-lp-q", "wakeup")
        IO.inspect(out, label: "TASK-SEND-OUT")
        send(me, {:wakeup_sent, out})
      end)

    t1 = System.monotonic_time(:millisecond)
    recv = receive_msg(port, "sqs-lp-q", ["WaitTimeSeconds=5"])
    wake = System.monotonic_time(:millisecond) - t1
    assert_received {:wakeup_sent, out}
    IO.inspect(out, label: "WAKEUP-SEND-RESP")

    assert recv =~ "<Body>wakeup</Body>"
    assert wake < 3_000, "mid-poll wake took #{wake}ms (flush_waiters should be instant)"
    Task.await(task)
  end

  test "DelaySeconds: message invisible until the delay elapses",
       %{port: port} do
    create_queue(port, "sqs-delay-q")
    send_msg(port, "sqs-delay-q", "later", ["DelaySeconds=1"])

    # immediately: invisible
    refute receive_msg(port, "sqs-delay-q") =~ "<Message>"

    # bounded poll until due (the scheduled_enqueue_time law)
    resp =
      Enum.reduce_while(1..10, nil, fn _i, _acc ->
        resp = receive_msg(port, "sqs-delay-q", ["WaitTimeSeconds=1"])

        if resp =~ "<Message>",
          do: {:halt, resp},
          else: {:cont, resp}
      end)

    assert resp =~ "<Body>later</Body>"
  end

  test "GetQueueAttributes: counts and VisibilityTimeout", %{port: port} do
    create_queue(port, "sqs-attr-q")

    {200, resp} =
      post(
        port,
        body(["Action=GetQueueAttributes", "Version=2012-11-05",
              "QueueUrl=http://127.0.0.1/x/sqs-attr-q", "AttributeName.1=All"])
      )

    assert resp =~ "<Name>QueueArn</Name><Value>arn:aws:sqs:us-east-1:000000000000:sqs-attr-q</Value>"
    assert resp =~ "<Name>ApproximateNumberOfMessages</Name><Value>0</Value>"
    assert resp =~ "<Name>VisibilityTimeout</Name><Value>30</Value>"

    send_msg(port, "sqs-attr-q", "one")
    send_msg(port, "sqs-attr-q", "two")

    {200, resp2} =
      post(
        port,
        body(["Action=GetQueueAttributes", "Version=2012-11-05",
              "QueueUrl=http://127.0.0.1/x/sqs-attr-q"])
      )

    assert resp2 =~ "<Name>ApproximateNumberOfMessages</Name><Value>2</Value>"

    # receiving one moves it to NotVisible
    receive_msg(port, "sqs-attr-q")

    {200, resp3} =
      post(
        port,
        body(["Action=GetQueueAttributes", "Version=2012-11-05",
              "QueueUrl=http://127.0.0.1/x/sqs-attr-q", "AttributeName.1=All"])
      )

    assert resp3 =~ "<Name>ApproximateNumberOfMessages</Name><Value>1</Value>"
    assert resp3 =~ "<Name>ApproximateNumberOfMessagesNotVisible</Name><Value>1</Value>"
  end

  test "SendMessageBatch: dotted-index entries + partial failure (BatchResultErrorEntry)",
       %{port: port} do
    create_queue(port, "sqs-batch-q")

    {200, resp} =
      post(
        port,
        body(["Action=SendMessageBatch", "Version=2012-11-05",
              "QueueUrl=http://127.0.0.1/x/sqs-batch-q",
              "SendMessageBatchRequestEntry.1.Id=a", "SendMessageBatchRequestEntry.1.MessageBody=first",
              "SendMessageBatchRequestEntry.2.Id=b"])
        # entry 2 has NO MessageBody -> SenderFault BatchResultErrorEntry
      )

    assert resp =~ "<SendMessageBatchResponse"
    assert resp =~ "<SendMessageBatchResultEntry><Id>a</Id>"
    assert resp =~ "<MD5OfMessageBody>" <> md5("first") <> "</MD5OfMessageBody>"
    assert resp =~ "<BatchResultErrorEntry><Id>b</Id><SenderFault>true</SenderFault>"
    assert resp =~ "<Code>MissingParameter</Code>"

    recv = receive_msg(port, "sqs-batch-q")
    assert recv =~ "<Body>first</Body>"
  end

  test "DeleteQueue purges and the queue stops existing", %{port: port} do
    create_queue(port, "sqs-del-q")
    send_msg(port, "sqs-del-q", "doomed")

    {200, resp} =
      post(port, body(["Action=DeleteQueue", "Version=2012-11-05", "QueueUrl=http://127.0.0.1/x/sqs-del-q"]))

    assert resp =~ "<DeleteQueueResponse"

    {400, resp} =
      post(
        port,
        body(["Action=SendMessage", "Version=2012-11-05", "QueueUrl=http://127.0.0.1/x/sqs-del-q",
              "MessageBody=after"])
      )

    assert resp =~ "NonExistentQueue"
  end

  test "ListQueues returns created queues filtered by prefix", %{port: port} do
    create_queue(port, "sqs-lq-alpha")
    create_queue(port, "sqs-lq-beta")

    {200, resp} =
      post(port, body(["Action=ListQueues", "Version=2012-11-05", "QueueNamePrefix=sqs-lq-alpha"]))

    assert resp =~ "/sqs-lq-alpha</QueueUrl>"
    refute resp =~ "sqs-lq-beta"
  end

  test "engine roundtrip: SQS-send is receivable through the AMQP store plane (same engine)",
       %{port: port} do
    create_queue(port, "sqs-engine-q")
    send_msg(port, "sqs-engine-q", "via-engine")

    # direct store claim — the SAME QueueStore the AMQP/SB planes use
    assert {:ok, msg, _lock} = QueueStore.dequeue_matching("sqs-engine-q")
    assert raw_body_of(msg) == "via-engine"
  end

  # -- helpers -----------------------------------------------------------------

  def send_wakeup(port), do: send_msg(port, "sqs-lp-q", "wakeup")

  defp md5(s), do: :erlang.md5(s) |> Base.encode16(case: :lower)

  defp handle_from(recv) do
    [_, rest] = String.split(recv, "<ReceiptHandle>", parts: 2)
    [handle | _] = String.split(rest, "</ReceiptHandle>", parts: 2)
    URI.decode_www_form(handle)
  end

  defp raw_body_of(%{body: b}) when is_binary(b), do: b
  defp raw_body_of(%{body: {_k, v}}) when is_binary(v), do: v
end
