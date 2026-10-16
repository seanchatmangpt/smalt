defmodule Smalt.Amqp.ConnectionTest do
  @moduledoc """
  Socket-level wire tests: scripted raw `:gen_tcp` client drives SASL ANONYMOUS
  handshake, open/begin, attach routing, transfer ingestion with server
  disposition, flow-credit delivery and disposition settlement
  (accepted / defer / deadletter), frame-split resilience, unauthorized-entity
  detach, and malformed-frame close.

  Client frames are built/decoded via `Smalt.Amqp.FrameCodec` (the same seam
  the server uses), so this exercises the real integration paths. NOT a
  permanent skip — tag `:amqp_wire` for coordinator inclusion.
  """

  use ExUnit.Case, async: false
  @moduletag :amqp_wire

  alias Smalt.Amqp.{Connection, FrameCodec}

  @header "AMQP\x00\x01\x00\x00"
  @sasl_header "AMQP\x03\x01\x00\x00"

  # ===========================================================================
  # Harness
  # ===========================================================================

  @test_key "test-shared-key-0123456789abcdef012345"

  setup do
    Application.put_env(:smalt, :sb_shared_key, @test_key)

    SmaltTest.Lifecycle.ensure_store_up()

    for table <- [:smalt_sb_queues, :smalt_sb_messages, :smalt_sb_locks, :smalt_sb_tokens] do
      if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    accept_task =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listener, 5000)
        {:ok, pid} = Connection.start_link(socket: sock)
        :ok = :gen_tcp.controlling_process(sock, pid)
        {:ok, pid}
      end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
    {:ok, conn} = Task.await(accept_task, 5000)

    queue = "test-queue-#{System.unique_integer([:positive])}"

    # the CBS claim cache may persist across tests; give this connection a
    # valid claim for its test queue (same verdict path as a real put-token)
    if GenServer.whereis(Smalt.Amqp.CbsRouter) do
      GenServer.stop(Smalt.Amqp.CbsRouter)
    end

    {:ok, _} = GenServer.start(Smalt.Amqp.CbsRouter, [], name: Smalt.Amqp.CbsRouter)

    sr = "sb://127.0.0.1:5672/" <> queue
    se = System.system_time(:second) + 600
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, @test_key, sr <> "\n" <> Integer.to_string(se)))

    token =
      "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

    request = %{
      operation: "put-token",
      type: "servicebus.windows.net:sastoken",
      name: sr,
      expiration: se,
      token: token
    }

    assert {:ok, {200, _}} = Smalt.Amqp.CbsRouter.put_token(Smalt.Amqp.CbsRouter, request, conn)

    %{
      client: client,
      conn: conn,
      queue: queue
    }
  end

  # ===========================================================================
  # SASL + open/begin handshake
  # ===========================================================================

  test "SASL ANONYMOUS handshake then open and begin", %{client: client} do
    :ok = :gen_tcp.send(client, @sasl_header)
    assert {:ok, @sasl_header} = recv_exact(client, 8)

    mech = recv_frame(client)
    assert mech.performative.performative == :sasl_mechanisms
    assert {:symbol, "ANONYMOUS"} in mech.performative.server_mechanisms

    :ok = send_bytes(client, enc_frame(:sasl, 0, {:sasl_init, %{mechanism: "ANONYMOUS"}}))

    outcome = recv_frame(client)
    assert outcome.performative.performative == :sasl_outcome
    assert outcome.performative.code == 0

    :ok = :gen_tcp.send(client, @header)
    assert {:ok, @header} = recv_exact(client, 8)

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:open, %{container_id: "test-client", max_frame_size: 65_536, channel_max: 65_535}})
      )

    opened = recv_frame(client)
    assert opened.performative.performative == :open
    assert opened.performative.container_id == "smalt-local"
    assert opened.performative.max_frame_size == 1_048_576

    :ok = send_bytes(client, enc_frame(:amqp, 0, {:begin, %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}}))

    begun = recv_frame(client)
    assert begun.performative.performative == :begin
    assert begun.performative.remote_channel == 0
  end

  # ===========================================================================
  # Sender link: transfer ingestion + server disposition accepted
  # ===========================================================================

  test "sender link transfer ingests message, accepted disposition returned", ctx do
    client = ctx.client
    :ok = handshake(client)

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:attach, %{name: "l1", handle: 0, role: false, target: %{address: ctx.queue}}})
      )

    at = recv_until(client, :attach)
    assert at.performative.role == true

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:transfer, %{handle: 0, delivery_id: 7, delivery_tag: <<1, 2, 3, 4>>, message_format: 0, settled: true, more: false}, {:sections, [{:body_amqp_value, "hello"}]}})
      )

    disp = recv_frame(client)
    assert disp.performative.performative == :disposition
    assert disp.performative.settled == true
    assert disp.performative.state == :accepted
    assert disp.performative.first == 7
    assert disp.performative.last == 7
  end

  # ===========================================================================
  # Frame-split resilience
  # ===========================================================================

  test "byte-chunked frame delivery survives reassembly", ctx do
    client = ctx.client
    :ok = handshake(client)

    attach = IO.iodata_to_binary(enc_frame(:amqp, 0, {:attach, %{name: "l1", handle: 0, role: false, target: %{address: ctx.queue}}}))

    for <<byte::8 <- attach>> do
      :ok = :gen_tcp.send(client, <<byte>>)
    end

    at = recv_until(client, :attach)
    assert at.performative.name == "l1"
  end

  # ===========================================================================
  # Receiver link: flow credit -> transfer with lock-token tag -> settle
  # ===========================================================================

  test "receiver flow credit delivers transfer; accepted settles message", ctx do
    client = ctx.client
    queue = ctx.queue
    :ok = handshake(client)

    # enqueue via sender link
    :ok = send_bytes(client, enc_frame(:amqp, 0, {:attach, %{name: "s1", handle: 0, role: false, target: %{address: queue}}}))
    assert %{performative: %{performative: :attach}} = recv_frame(client)

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:transfer, %{handle: 0, delivery_id: 7, delivery_tag: <<1, 2, 3, 4>>, message_format: 0, settled: true, more: false}, {:sections, [{:body_amqp_value, "m1"}]}})
      )

    assert %{performative: %{performative: :disposition, state: :accepted}} = recv_frame(client)

    # receiver link
    :ok = send_bytes(client, enc_frame(:amqp, 0, {:attach, %{name: "r1", handle: 1, role: true, source: %{address: queue}}}))
    at = recv_until(client, :attach)
    assert at.performative.role == false

    # credit via link-credit (no handle = broadcast to our sender-role links)
    :ok = send_bytes(client, enc_frame(:amqp, 0, {:flow, %{link_credit: 10}}))

    tr = recv_frame(client)
    assert tr.performative.performative == :transfer
    assert tr.performative.handle == 1
    assert is_integer(tr.performative.delivery_id)
    # raw 16-byte uuid lock token (rhea uuid_to_string on the client side)
    tag = tr.performative.delivery_tag
    assert {:uuid, <<_::128>>} = tag
    assert tr.performative.settled in [false, nil]

    delivery_id = tr.performative.delivery_id

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:disposition, %{role: true, first: delivery_id, last: delivery_id, settled: true, state: :accepted}})
      )

    Process.sleep(50)
    assert count_state(queue, :any) == 0
  end

  # ===========================================================================
  # Disposition variants: modified+undeliverable-here -> defer, rejected -> DLQ
  # ===========================================================================

  test "modified undeliverable-here defers; rejected deadletters", ctx do
    client = ctx.client
    queue = ctx.queue
    :ok = handshake(client)

    :ok = send_bytes(client, enc_frame(:amqp, 0, {:attach, %{name: "s1", handle: 0, role: false, target: %{address: queue}}}))
    assert %{performative: %{performative: :attach}} = recv_frame(client)

    for id <- 1..2 do
      :ok =
        send_bytes(
          client,
          enc_frame(:amqp, 0, {:transfer, %{handle: 0, delivery_id: id, delivery_tag: <<id::8>>, message_format: 0, settled: true, more: false}, {:sections, [{:body_amqp_value, "m#{id}"}]}})
        )

      assert %{performative: %{performative: :disposition, state: :accepted}} = recv_frame(client)
    end

    :ok = send_bytes(client, enc_frame(:amqp, 0, {:attach, %{name: "r1", handle: 1, role: true, source: %{address: queue}}}))
    assert %{performative: %{performative: :attach}} = recv_frame(client)
    :ok = send_bytes(client, enc_frame(:amqp, 0, {:flow, %{link_credit: 2}}))

    t1 = recv_frame(client)
    t2 = recv_frame(client)
    assert %{performative: %{performative: :transfer}} = t1
    assert %{performative: %{performative: :transfer}} = t2
    id1 = t1.performative.delivery_id
    id2 = t2.performative.delivery_id

    # modified with undeliverable-here -> defer
    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:disposition, %{role: true, first: id1, last: id1, settled: true, state: {:modified, %{undeliverable_here: true}}}})
      )

    # rejected -> deadletter
    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:disposition, %{role: true, first: id2, last: id2, settled: true, state: {:rejected, nil}}})
      )

    Process.sleep(50)
    assert count_state(queue, :deferred) == 1
    assert count_state(queue, :available) == 0
    assert count_state(queue <> "/$deadletterqueue", :any) == 1
  end

  # ===========================================================================
  # Unauthorized entity (enforced only while CbsRouter process is running)
  # ===========================================================================

  test "queue attach without CBS token is detached UNAUTHORIZED_ENTITY", ctx do
    client = ctx.client
    queue = ctx.queue
    :ok = handshake(client)

    # setup grants a claim for ctx.queue only; an entity without a claim
    # must be detached UNAUTHORIZED_ENTITY
    other_queue = "no-claim-" <> queue

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:attach, %{name: "l1", handle: 0, role: false, target: %{address: other_queue}}})
      )

    # rhea (core-amqp) requires the broker attach echo BEFORE any detach
    # (bare detach raises "Invalid handle N" client-side), so the refusal is
    # attach echo first, then the typed error detach.
    echo = recv_frame(client)
    assert echo.performative.performative == :attach
    assert echo.performative.handle == 0

    det = recv_frame(client)
    assert det.performative.performative == :detach
    assert det.performative.handle == 0
    assert det.performative.closed == true
    assert error_condition(det.performative.error) == "amqp:unauthorized-access"
    assert error_description(det.performative.error) == "UNAUTHORIZED_ENTITY"
  end

  # ===========================================================================
  # Malformed frame handling
  # ===========================================================================

  test "bad protocol header yields close with error then socket close", %{client: client} do
    :ok = handshake(client)
    :ok = :gen_tcp.send(client, "XXXXYYYY")

    closed = recv_frame(client)
    assert closed.performative.performative == :close
    assert error_condition(closed.performative.error) == "amqp:internal-error"
    assert error_description(closed.performative.error) in [":bad_protocol_header", ":frame_too_size"]

    assert {:error, :closed} = :gen_tcp.recv(client, 1, 2000)
  end

  test "oversized frame is rejected", %{client: client} do
    :ok = handshake(client)

    :ok = :gen_tcp.send(client, <<5_000_000::unsigned-integer-size(32)>>)
    :ok = :gen_tcp.send(client, :binary.copy(<<0>>, 64))

    closed = recv_frame(client)
    assert closed.performative.performative == :close
    assert error_condition(closed.performative.error) == "amqp:internal-error"

    assert {:error, :closed} = :gen_tcp.recv(client, 1, 2000)
  end

  # ===========================================================================
  # Multi-session liveness (census stall repro)
  # ===========================================================================

  @tag :stall_repro
  test "new-session sender works after an unsettled receiver delivery", ctx do
    client = ctx.client
    :ok = handshake(client)

    # sender: ingest m1 on session channel 0
    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:attach, %{name: "tx", handle: 0, role: false, target: %{address: ctx.queue}}})
      )

    at = recv_until(client, :attach)
    assert at.performative.role == true

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {
          :transfer,
          %{handle: 0, delivery_id: 1, delivery_tag: <<1>>, message_format: 0, settled: true, more: false},
          {:sections, [{:body_amqp_value, "m1"}]}
        })
      )

    disp = recv_frame(client)
    assert disp.performative.performative == :disposition

    # receiver with credit 1 on channel 0
    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:attach, %{name: "rx", handle: 1, role: true, source: %{address: ctx.queue}}})
      )

    at2 = recv_until(client, :attach)
    assert at2.performative.role == false
    c = send_bytes(client, enc_frame(:amqp, 0, {:flow, %{handle: 1, link_credit: 1}}))
    assert c == :ok

    transfer = recv_until(client, :transfer)
    assert transfer[:payload]

    # WITHOUT settling: open session channel 1 + sender there (census shape:
    # core-amqp opens a fresh session per sender)
    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:begin, %{next_outgoing_id: 10, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}})
      )

    begun = recv_frame(client)
    assert begun.performative.performative == :begin
    assert begun.performative.remote_channel == 0

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 1, {:attach, %{name: "tx2", handle: 0, role: false, target: %{address: ctx.queue}}})
      )

    at3 = recv_until(client, :attach)
    assert at3.performative.role == true

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 1, {
          :transfer,
          %{handle: 0, delivery_id: 1, delivery_id_note: :ch1, delivery_tag: <<2>>, message_format: 0, settled: true, more: false},
          {:sections, [{:body_amqp_value, "m2"}]}
        })
      )

    disp2 = recv_frame(client)
    assert disp2.performative.performative == :disposition
    assert disp2.performative.state == :accepted
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # ===========================================================================
  # Session exclusivity (census exclusive-session probe parity)
  # ===========================================================================

  test "session receiver: lock grant, second accept refused, renew still extends", ctx do
    client = ctx.client
    queue = ctx.queue
    sid = "s-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = handshake(client)

    # real store collaborator: enqueue one session message
    assert {:ok, _} = Smalt.Amqp.QueueStore.enqueue(queue, "m", session_id: sid)

    # first session receiver (handle 1)
    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:attach, %{
          name: "r1",
          handle: 1,
          role: true,
          source: %{address: queue, filter: {:map_rhea, %{{:symbol, "com.microsoft:session-filter"} => sid}}}
        }})
      )

    at1 = recv_until(client, :attach)
    assert at1.performative.role == false
    props = at1.performative.properties
    ticks = props["com.microsoft:locked-until-utc"]
    assert is_integer(ticks) and ticks > 630_000_000_000_000_000

    # second accept on the same session id (handle 2): attach echo, then a
    # typed session-cannot-be-locked detach. No detach may reach handle 1.
    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:attach, %{
          name: "r2",
          handle: 2,
          role: true,
          source: %{address: ctx.queue, filter: {:map_rhea, %{{:symbol, "com.microsoft:session-filter"} => sid}}}
        }})
      )

    frames = recv_many(client, 2)
    assert [%{performative: %{performative: :attach}}, %{performative: %{performative: :detach}} = det] = frames
    assert det.performative.handle == 2
    assert error_condition(det.performative.error) == "com.microsoft:session-cannot-be-locked"

    # handle 1 stays open: renewing the session lock over $management still
    # extends the expiry (census exclusiveSessionCase renew step).
    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:attach, %{name: "mg1", handle: 3, role: true, source: %{address: queue <> "/$management"}}})
      )

    assert %{performative: %{performative: :attach}} = recv_frame(client)

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:attach, %{name: "mg2", handle: 4, role: false, target: %{address: queue <> "/$management"}}})
      )

    assert %{performative: %{performative: :attach}} = recv_frame(client)

    body = %{"session-id" => sid}

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:transfer, %{handle: 3, delivery_id: 21, delivery_tag: <<>>, message_format: 0, settled: true, more: false},
           {:sections, [
             {:properties, %{correlation_id: "c1"}},
             {:application_properties, %{"operation" => "com.microsoft:renew-session-lock", "associated-link-name" => "r1"}},
             {:body_amqp_value, body}
           ]}})
      )

    reply = recv_until(client, :transfer)
    assert %{performative: %{performative: :transfer}} = reply

    {:ok, sections} = FrameCodec.decode_message(reply.payload)
    assert {:body_amqp_value, %{"expiration" => {:timestamp, exp_ms}}} =
             Enum.find(sections, &match?({:body_amqp_value, _}, &1))

    assert exp_ms > System.system_time(:millisecond)
  end

  # ===========================================================================
  # Outbound encode-raise containment (lens-4 cycle-3 falsifier)
  # ===========================================================================

  test "unencodable outbound app-props: typed close, no crash, lock released", ctx do
    client = ctx.client
    queue = ctx.queue
    :ok = handshake(client)

    # store-collaborator injection: app-props value no codec clause covers
    assert {:ok, _} =
             Smalt.Amqp.QueueStore.enqueue(queue, "m", app_props: %{"bad" => {1, 2}})

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:attach, %{name: "r", handle: 1, role: true, source: %{address: queue}}})
      )

    assert %{performative: %{performative: :attach}} = recv_frame(client)
    :ok = send_bytes(client, enc_frame(:amqp, 0, {:flow, %{link_credit: 5}}))

    # the connection must NOT crash: the close frame arrives on the same
    # socket, and the locked message is back to :available (reclaimable)
    assert %{performative: %{performative: :close}} = recv_until(client, :close)

    assert {:ok, %{state: state}} =
             Smalt.Store.get(:smalt_sb_messages, {queue, 1}) |> then(fn
               {:ok, m} -> {:ok, m}
               :error -> {:error, :gone}
             end)

    # Exact state, not an allow-list: the lock-leak mutation (dropping the
    # QueueStore.release before error_close) leaves :locked and must be
    # killed by this assertion. Release is synchronous before the close
    # frame is written, so :available is deterministic on close receipt.
    assert state == :available
    Process.sleep(50)

    # connection process alive: a fresh begin on the same socket still answers
    :ok = send_bytes(client, enc_frame(:amqp, 0, {:begin, %{next_outgoing_id: 1, incoming_window: 100, outgoing_window: 100}}))
  end

  # ===========================================================================
  # Peer max_frame_size clamp (lens-4 cycle-3 mutation falsifier)
  # ===========================================================================

  test "peer advertising >1MB max_frame_size still gets frames split at the decode cap", ctx do
    client = ctx.client
    queue = ctx.queue
    :ok = handshake(client)

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:open, %{container_id: "big-peer", max_frame_size: 16_000_000, channel_max: 65_535}})
      )

    assert %{performative: %{performative: :open}} = recv_frame(client)

    :ok =
      send_bytes(client, enc_frame(:amqp, 0, {:begin, %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000}}))

    assert %{performative: %{performative: :begin}} = recv_frame(client)

    # a 1.5MB body exceeds OUR decode cap (1_048_576) but not the peer's
    # advertised 16MB: with the clamp active the broker MUST split (more=true
    # on the first transfer, first frame <= cap); with the clamp mutated to
    # identity the single 1.5MB frame goes out unsplit and this fails.
    :ok = Smalt.Amqp.QueueStore.enqueue(queue, :crypto.strong_rand_bytes(1_500_000))

    :ok =
      send_bytes(client, enc_frame(:amqp, 0, {:attach, %{name: "r", handle: 1, role: true, source: %{address: queue}}}))

    assert %{performative: %{performative: :attach}} = recv_frame(client)
    :ok = send_bytes(client, enc_frame(:amqp, 0, {:flow, %{handle: 1, link_credit: 1}}))

    # raw frame size off the wire (recv_until skips flow frames silently, so
    # read the header explicitly for the size bound)
    {:ok, hdr} =
      case :gen_tcp.recv(client, 8, 2000) do
        {:ok, h} -> {:ok, h}
        {:error, :closed} -> flunk("connection closed before transfer")
      end

    <<size::unsigned-integer-size(32), _doff, _type, _ch::16>> = hdr
    body = elem(recv_exact(client, size - 8), 1)
    assert %{performative: %{performative: :transfer, more: true}} = FrameCodec.decode_frame(hdr <> body)

    # clamp bound: frame never exceeds our local decode cap even though the
    # peer advertised 16MB
    assert size <= 1_048_576
  end

  defp recv_many(client, n, acc \\ [])

  defp recv_many(_client, 0, acc), do: Enum.reverse(acc)

  defp recv_many(client, n, acc) do
    f = recv_frame(client)
    recv_many(client, n - 1, [f | acc])
  end

  defp enc_frame(layer, channel, performative), do: FrameCodec.encode_frame(layer, channel, performative)

  defp send_bytes(client, iodata), do: :gen_tcp.send(client, iodata)

  # the server interleaves link-credit flow frames; skip them
  defp recv_until(client, name, timeout \\ 2000)

  defp recv_until(client, name, timeout) do
    frame = recv_frame(client, timeout)

    if frame.performative.performative == name,
      do: frame,
      else: recv_until(client, name, timeout)
  end

  defp recv_frame(client, timeout \\ 2000) do
    frame = do_recv_frame(client, timeout)

    # the server interleaves link-credit flow frames; no test expects them
    if frame.performative.performative == :flow do
      recv_frame(client, timeout)
    else
      frame
    end
  end

  defp do_recv_frame(client, timeout) do
    {:ok, hdr} = recv_exact(client, 8, timeout)
    <<size::unsigned-integer-size(32), _doff, _type, _channel::16>> = hdr
    body = elem(recv_exact(client, size - 8, timeout), 1)
    buf = hdr <> body

    case FrameCodec.decode_frame(buf) do
      {:ok, frame} -> frame
      other -> flunk("frame decode failed: #{inspect(other)}")
    end
  end

  defp recv_exact(client, n, timeout \\ 2000)

  defp recv_exact(_client, 0, _timeout), do: {:ok, <<>>}

  defp recv_exact(client, n, timeout) do
    case :gen_tcp.recv(client, n, timeout) do
      {:ok, data} -> {:ok, data}
      {:error, :closed} -> {:ok, <<>>}
    end
  end

  defp error_condition([{:symbol, c} | _]) when is_binary(c), do: c
  defp error_condition(%{condition: c}) when is_binary(c), do: c

  defp error_description([_sym, d | _]) when is_binary(d), do: d
  defp error_description(%{description: d}) when is_binary(d), do: d

  defp count_state(queue, :any) do
    length(:ets.select(:smalt_sb_messages, [{{{queue, :"$1"}, :_}, [], [:"$1"]}]))
  end

  defp count_state(queue, state) do
    length(:ets.select(:smalt_sb_messages, [{{{queue, :"$1"}, %{state: state}}, [], [:"$1"]}]))
  end

  defp handshake(client) do
    :ok = :gen_tcp.send(client, @sasl_header)
    assert {:ok, @sasl_header} = recv_exact(client, 8)
    recv_frame(client)
    :ok = send_bytes(client, enc_frame(:sasl, 0, {:sasl_init, %{mechanism: "ANONYMOUS"}}))
    recv_frame(client)
    :ok = :gen_tcp.send(client, @header)
    assert {:ok, @header} = recv_exact(client, 8)

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:open, %{container_id: "test-client", max_frame_size: 65_536, channel_max: 65_535}})
      )

    recv_frame(client)

    :ok =
      send_bytes(
        client,
        enc_frame(:amqp, 0, {:begin, %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}})
      )

    recv_frame(client)
    :ok
  end
end
