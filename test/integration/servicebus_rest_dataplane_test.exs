defmodule Smalt.Integration.ServiceBusRestDataplaneTest do
  # SB-REST lane court: real Smalt.EgressRouter dispatch (real plug chain,
  # real SAS verifier, real QueueStore ETS store), assertions on actual wire
  # responses and real store state — Chicago discipline, no mocks.
  #
  # AMQP cross-check disclosure: the message sent over REST is received via
  # Smalt.Amqp.QueueStore.dequeue_matching/2 — the exact claim/lock path the
  # AMQP connection lane drives (connection.ex) — at store level. A live-socket
  # cross-check (real AMQP client over the wire) is NOT exercised here.
  use ExUnit.Case, async: false

  alias Smalt.Amqp.QueueStore
  alias Smalt.Amqp.SasVerifier

  @ns "sbns"

  defp unique_queue,
    do: "sbrest-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

  # Mint a real SAS token against the configured endpoint, same string-to-sign
  # ("{sr}\n{se}") the AMQP CBS tests mint — one truth with SasVerifier.
  defp mint_sas(queue) do
    sr = SasVerifier.endpoint() <> "/" <> queue
    se = System.system_time(:second) + 600
    key = SasVerifier.shared_key()
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}"))

    "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"
  end

  defp call(method, path, opts \\ []) do
    conn =
      Plug.Test.conn(method, path, opts[:body])
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> then(fn c ->
        Enum.reduce(opts, c, fn
          {:auth, token}, c -> Plug.Conn.put_req_header(c, "authorization", token)
          {:hdr, {k, v}}, c -> Plug.Conn.put_req_header(c, k, v)
          _, c -> c
        end)
      end)

    Smalt.EgressRouter.call(conn, [])
  end

  defp send_message(queue, opts \\ []) do
    bp = opts[:bp] || %{"MessageId" => "rest-msg-1"}

    call(:post, "/#{@ns}/#{queue}/messages",
      auth: mint_sas(queue),
      body: opts[:body] || "rest-body",
      hdr: {"content-type", "text/plain"},
      hdr: {"brokerproperties", Jason.encode!(bp)}
    )
  end

  test "send: 201 and store-visible brokered properties" do
    q = unique_queue()
    {:ok, _} = QueueStore.ensure_queue(q)

    conn =
      send_message(q, bp: %{"MessageId" => "mid-1", "SessionId" => "s1", "PartitionKey" => "pk1"})

    assert conn.status == 201
    assert conn.resp_body == ""

    {:ok, [msg]} = QueueStore.peek(q)
    assert msg.message_id == "mid-1"
    assert msg.session_id == "s1"
    assert msg.annotations["x-opt-partition-key"] == "pk1"
    assert msg.body == "rest-body"
  end

  test "send: api-version query param tolerated" do
    q = unique_queue()
    {:ok, _} = QueueStore.ensure_queue(q)

    conn =
      call(:post, "/#{@ns}/#{q}/messages?api-version=2021-06-01&timeout=30",
        auth: mint_sas(q),
        body: "v",
        hdr: {"content-type", "text/plain"}
      )

    assert conn.status == 201
  end

  test "send: bad SAS -> typed 401 envelope + WWW-Authenticate" do
    q = unique_queue()
    {:ok, _} = QueueStore.ensure_queue(q)

    bad = String.replace(mint_sas(q), "sig=", "sig=AAAA")

    conn =
      call(:post, "/#{@ns}/#{q}/messages",
        auth: bad,
        body: "x",
        hdr: {"content-type", "text/plain"}
      )

    assert conn.status == 401
    assert %{"error" => %{"code" => "INVALID_LOCAL_SAS"}} = Jason.decode!(conn.resp_body)
    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == ["SharedAccessSignature"]
  end

  test "send: unknown queue -> 404 MessagingEntityNotFound" do
    q = unique_queue()

    conn = send_message(q)

    assert conn.status == 404
    assert %{"error" => %{"code" => "MessagingEntityNotFound"}} = Jason.decode!(conn.resp_body)
  end

  test "peek-lock receive: 200 + BrokerProperties + Location + brokered-encoding" do
    q = unique_queue()
    {:ok, _} = QueueStore.ensure_queue(q)
    {:ok, _} = QueueStore.enqueue(q, "hello-rest", message_id: "peek-1")
    {:ok, _} = QueueStore.enqueue(q, "hello-rest-2", message_id: "peek-2")

    conn = call(:post, "/#{@ns}/#{q}/messages/head", auth: mint_sas(q))

    assert conn.status == 200
    assert conn.resp_body == "hello-rest"

    [bp] = Plug.Conn.get_resp_header(conn, "brokerproperties")
    bp = Jason.decode!(bp)
    assert bp["MessageId"] == "peek-1"
    assert bp["DeliveryCount"] == 1
    assert bp["SequenceNumber"] == 1

    [loc] = Plug.Conn.get_resp_header(conn, "location")
    assert loc =~ "/#{q}/messages/1/"

    [enc] = Plug.Conn.get_resp_header(conn, "x-ms-brokered-encoding")
    assert enc == "application/atom+xml"

    {:ok, msgs} = QueueStore.peek(q)
    locked = Enum.find(msgs, &(&1.seq == 1))
    assert locked.state == :locked

    conn2 = call(:post, "/#{@ns}/#{q}/messages/head", auth: mint_sas(q))
    assert conn2.resp_body == "hello-rest-2"
  end

  test "complete (DELETE lock URI): 200 and message gone from the store" do
    q = unique_queue()
    {:ok, _} = QueueStore.ensure_queue(q)
    {:ok, _} = QueueStore.enqueue(q, "bye")
    {:ok, msg, lock} = QueueStore.dequeue_matching(q)

    conn =
      call(:delete, "/#{@ns}/#{q}/messages/#{msg.seq}/#{lock.lock_token}", auth: mint_sas(q))

    assert conn.status == 200
    assert {:ok, []} = QueueStore.peek(q)
  end

  test "receive-and-delete (DELETE head): 200 consumes; empty queue -> 204" do
    q = unique_queue()
    {:ok, _} = QueueStore.ensure_queue(q)
    {:ok, _} = QueueStore.enqueue(q, "rd")

    conn = call(:delete, "/#{@ns}/#{q}/messages/head", auth: mint_sas(q))
    assert conn.status == 200
    assert conn.resp_body == "rd"
    assert {:ok, []} = QueueStore.peek(q)

    conn2 = call(:delete, "/#{@ns}/#{q}/messages/head", auth: mint_sas(q))
    assert conn2.status == 204
  end

  test "unlock (PUT lock URI): message returns to :available" do
    q = unique_queue()
    {:ok, _} = QueueStore.ensure_queue(q)
    {:ok, _} = QueueStore.enqueue(q, "abandon-me")
    {:ok, msg, lock} = QueueStore.dequeue_matching(q)

    conn = call(:put, "/#{@ns}/#{q}/messages/#{msg.seq}/#{lock.lock_token}", auth: mint_sas(q))

    assert conn.status == 200
    assert {:ok, [m]} = QueueStore.peek(q)
    assert m.state == :available
  end

  test "renew (POST lock URI): 200 and the token still settles afterwards" do
    q = unique_queue()
    {:ok, _} = QueueStore.ensure_queue(q)
    {:ok, _} = QueueStore.enqueue(q, "renew")
    {:ok, msg, lock} = QueueStore.dequeue_matching(q)

    conn = call(:post, "/#{@ns}/#{q}/messages/#{msg.seq}/#{lock.lock_token}", auth: mint_sas(q))
    assert conn.status == 200

    conn2 =
      call(:delete, "/#{@ns}/#{q}/messages/#{msg.seq}/#{lock.lock_token}", auth: mint_sas(q))

    assert conn2.status == 200
  end

  test "x-ms-brokered-encoding: unsupported value -> 400 InvalidBrokeredEncoding" do
    q = unique_queue()
    {:ok, _} = QueueStore.ensure_queue(q)

    conn =
      call(:post, "/#{@ns}/#{q}/messages",
        auth: mint_sas(q),
        body: "x",
        hdr: {"content-type", "text/plain"},
        hdr: {"x-ms-brokered-encoding", "application/octet-stream"}
      )

    assert conn.status == 400
    assert %{"error" => %{"code" => "InvalidBrokeredEncoding"}} = Jason.decode!(conn.resp_body)
  end

  test "AMQP cross-check (store-level, disclosed): REST send receivable via dequeue_matching" do
    q = unique_queue()
    {:ok, _} = QueueStore.ensure_queue(q)

    conn = send_message(q, bp: %{"MessageId" => "via-rest"})
    assert conn.status == 201

    {:ok, msg, _lock} = QueueStore.dequeue_matching(q)
    assert msg.message_id == "via-rest"
    assert msg.body == "rest-body"
  end

  test "session message sent via REST is sessionful-receivable" do
    q = unique_queue()
    {:ok, _} = QueueStore.ensure_queue(q)

    conn =
      send_message(q, bp: %{"MessageId" => "sess-1", "SessionId" => "sess-a"}, body: "sess-body")

    assert conn.status == 201

    {:ok, msg, _lock} = QueueStore.dequeue_matching(q, session_id: "sess-a")
    assert msg.message_id == "sess-1"
    assert msg.body == "sess-body"
  end
end
