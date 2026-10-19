defmodule Smalt.Azsim.IntegrationPlaneTest do
  @moduledoc """
  AZB-07 - integration plane profile (Service Bus AMQP + Event Grid).

  Accept (ticket, binding): send/receive/complete/abandon/deadletter round-trip;
  oversize frame typed close (`amqp:frame-size-too-small`); Event Grid
  subscriber crash => redelivered count >= 1 with the same `id`.

  Falsifier: an Event Grid event published and never delivered after subscriber
  recovery - witnessed by the anti-vacuity shim run (ack-before-dispatch)
  FAILING this suite's loss assert, then byte-exact restore.
  """

  use ExUnit.Case, async: false

  alias Smalt.Amqp.FrameCodec
  alias Smalt.Amqp.QueueStore
  alias Smalt.Messaging.EventGrid

  @header "AMQP" <> <<0, 1, 0, 0>>
  @sasl_header "AMQP" <> <<3, 1, 0, 0>>

  setup do
    SmaltTest.Lifecycle.ensure_store_up()

    for table <- [:smalt_sb_queues, :smalt_sb_messages, :smalt_sb_locks, :smalt_sb_tokens] do
      if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  end

  # ===========================================================================
  # 1. Service Bus round-trip (real QueueStore, the wire's own seam)
  # ===========================================================================

  test "send/receive/complete round-trip" do
    queue = "it-plane-#{System.unique_integer([:positive])}"

    assert {:ok, _} = QueueStore.enqueue(queue, "payload-1")
    assert {:ok, msg, _lock} = QueueStore.dequeue_matching(queue)
    assert msg.body == "payload-1"
    assert msg.delivery_count == 1
    assert :ok = QueueStore.complete(queue, msg.seq)
    assert :empty = QueueStore.dequeue_matching(queue)
  end

  test "abandon requeues; deadletter after max-delivery-count" do
    queue = "it-plane-#{System.unique_integer([:positive])}"

    # ARM resource record pins maxDeliveryCount = 2 (queue_settings reads it).
    :ets.insert(:smalt_resources, {
      "/subscriptions/s/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/ns/queues/" <>
        String.downcase(queue),
      %{"properties" => %{"maxDeliveryCount" => 2}}
    })

    assert {:ok, _} = QueueStore.enqueue(queue, "poison")
    assert {:ok, m1, _l1} = QueueStore.dequeue_matching(queue)
    assert m1.delivery_count == 1

    # Abandon 1: requeued, delivery_count preserved.
    assert :ok = QueueStore.release(queue, m1.seq)
    assert {:ok, m2, _l2} = QueueStore.dequeue_matching(queue)
    assert m2.seq == m1.seq
    assert m2.delivery_count == 2

    # Abandon 2 hits max-delivery-count => deadletter (MaxDeliveryCountExceeded).
    assert :ok = QueueStore.release(queue, m2.seq)

    dlq = QueueStore.deadletter_queue(queue)
    assert {:ok, dl} = Smalt.Store.get(:smalt_sb_messages, {dlq, 1})
    assert dl.body == "poison"
    assert dl.annotations["DeadLetterReason"] == "MaxDeliveryCountExceeded"
  end

  # ===========================================================================
  # 2. Oversize frame: typed close amqp:frame-size-too-small, no crash
  # ===========================================================================

  test "oversize frame closes with amqp:frame-size-too-small" do
    SmaltTest.Env.put_restored(amqp: [sasl_mechanisms: [:anonymous], max_frame_size: 2048])

    {client, conn} = wire_conn!()

    try do
      :ok = handshake(client)

      # Declared frame size 4096 > configured max 2048 => typed close.
      :ok = :gen_tcp.send(client, <<4096::unsigned-integer-size(32)>>)
      :ok = :gen_tcp.send(client, :binary.copy(<<0>>, 64))

      closed = recv_frame(client)
      assert closed.performative.performative == :close
      assert error_condition(closed.performative.error) == "amqp:frame-size-too-small"
      assert {:error, :closed} = :gen_tcp.recv(client, 1, 2000)

      refute Process.alive?(conn)
    after
      :gen_tcp.close(client)
    end
  end

  test "profile excluding :anonymous refuses SASL with typed unauthorized-access" do
    SmaltTest.Env.put_restored(amqp: [sasl_mechanisms: [:plain]])

    {client, conn} = wire_conn!()

    try do
      :ok = :gen_tcp.send(client, @sasl_header)
      assert {:ok, @sasl_header} = recv_exact(client, 8)

      mech = recv_frame(client)
      assert mech.performative.performative == :sasl_mechanisms
      # Wire-compat pinion verbatim: exactly ANONYMOUS is advertised.
      assert mech.performative.server_mechanisms == [{:symbol, "ANONYMOUS"}]

      :ok = :gen_tcp.send(client, FrameCodec.encode_frame(:sasl, 0, {:sasl_init, %{mechanism: "ANONYMOUS"}}))

      outcome = recv_frame(client)
      assert outcome.performative.performative == :sasl_outcome
      assert outcome.performative.code == 1

      closed = recv_frame(client)
      assert closed.performative.performative == :close
      assert error_condition(closed.performative.error) == "amqp:unauthorized-access"
      refute Process.alive?(conn)
    after
      :gen_tcp.close(client)
    end
  end

  # ===========================================================================
  # 3. EH partition detach-forced + clean relink
  # ===========================================================================

  test "partition detach sends amqp:link:detach-forced; relink delivers" do
    {client, conn} = wire_conn!()

    partition = "0"

    eh_address =
      "/eventhubs/it-hub-" <> "#{System.unique_integer([:positive])}" <> "/partitions/" <> partition

    try do
      :ok = handshake(client)

      # Receiver link on the partition.
      :ok =
        :gen_tcp.send(
          client,
          FrameCodec.encode_frame(:amqp, 0, {:attach, %{name: "it-r", handle: 0, role: true, source: %{address: eh_address}}})
        )

      assert %{performative: %{performative: :attach}} = recv_frame(client)

      # Broker-forced partition detach: typed error, connection stays up.
      :ok = Smalt.Amqp.Connection.force_partition_detach(conn, eh_address)
      det = recv_until(client, :detach)
      assert det.performative.handle == 0
      assert det.performative.closed == true
      assert error_condition(det.performative.error) == "amqp:link:detach-forced"

      # Clean relink: re-attach the same partition, grant credit, send an
      # event via the in-process API, receive it on the relinked receiver.
      :ok =
        :gen_tcp.send(
          client,          FrameCodec.encode_frame(:amqp, 0,
            {:attach, %{name: "it-r2", handle: 0, role: true, source: %{address: eh_address}}}
          )
        )

      assert %{performative: %{performative: :attach}} = recv_frame(client)
      :ok = :gen_tcp.send(client, FrameCodec.encode_frame(:amqp, 0, {:flow, %{handle: 0, link_credit: 10}}))

      hub = "it-hub-" <> hub_suffix(eh_address)

      assert {:ok, 1, _} = Smalt.Messaging.EventHubs.send_event(hub, "post-relink-event")

      tr = recv_until(client, :transfer, 3000)
      assert {:ok, sections} = FrameCodec.decode_message(tr.payload)

      body =
        Enum.find_value(sections, fn
          {:body_data, b} -> b
          _ -> nil
        end)

      assert body == "post-relink-event"
    after
      :gen_tcp.close(client)
    end
  end

  # ===========================================================================
  # 4. Event Grid: at-least-once, dedup, crash => redelivery, same id
  # ===========================================================================

  test "event grid: publish/ack round-trip + duplicate id deduped" do
    topic = unique_topic()
    EventGrid.reset(topic)
    EventGrid.subscribe(topic, :sub)

    assert :fresh = EventGrid.publish(topic, %{id: "e1", data: "x"})
    assert :duplicate = EventGrid.publish(topic, %{id: "e1", data: "x"})

    assert_receive {:event_grid, ^topic, :sub, "e1", _}, 2000
    assert :ok = EventGrid.ack(topic, :sub, "e1")
    assert {0, nil, true} = EventGrid.status(topic, :sub)
  end

  test "event grid: subscriber crash => redelivery with same id (never loss)" do
    topic = unique_topic()
    EventGrid.reset(topic)

    test_pid = self()

    sub_pid =
      start_supervised!(%{
        id: :azb07_sub1,
        start:
          {Task, :start_link,
           [
             fn ->
               receive do
                 {:event_grid, t, :sub, id, _ev} -> send(test_pid, {:got1, t, id})
               end
             end
           ]},
        restart: :temporary
      })

    EventGrid.subscribe(topic, :sub, sub_pid)
    assert :fresh = EventGrid.publish(topic, %{id: "crash-1"})

    # Subscriber receives but crashes WITHOUT acking.
    assert_receive {:got1, ^topic, "crash-1"}, 2000

    # Recovery: a new pid re-subscribes the same subscription name.
    sub2_pid =
      start_supervised!(%{
        id: :azb07_sub2,
        start:
          {Task, :start_link,
           [
             fn ->
               receive do
                 {:event_grid, t, :sub, id, _ev} -> send(test_pid, {:got2, t, id})
               end
             end
           ]},
        restart: :temporary
      })

    EventGrid.subscribe(topic, :sub, sub2_pid)

    # Redelivery: same id, count >= 1 (exactly one on recovery).
    assert_receive {:got2, ^topic, "crash-1"}, 2000
  end

  test "event grid: event published while down is delivered after recovery (falsifier guard)" do
    topic = unique_topic()
    EventGrid.reset(topic)

    test_pid = self()

    sub_pid =
      start_supervised!(%{
        id: :azb07_sub3,
        start: {Task, :start_link, [fn -> receive do _ -> :ok end end]},
        restart: :temporary
      })

    EventGrid.subscribe(topic, :sub, sub_pid)
    send(sub_pid, :azb07_crash)
    Process.exit(sub_pid, :kill)

    # Wait for the DOWN (no sleep: poll real state via a bounded eventually).
    SmaltTest.AssertEventually.eventually(
      fn ->
        case EventGrid.status(topic, :sub) do
          {_, _, false} -> {:ok, :down_observed}
          _ -> :retry
        end
      end,
      observable: "subscriber marked down"
    )

    assert :fresh = EventGrid.publish(topic, %{id: "down-1"})
    assert {1, nil, false} = EventGrid.status(topic, :sub)

    sub4_pid =
      start_supervised!(%{
        id: :azb07_sub4,
      start:
        {Task, :start_link,
         [
           fn ->
             receive do
               {:event_grid, t, :sub, id, _ev} -> send(test_pid, {:got3, t, id})
             end
           end
         ]},
      restart: :temporary
    })

    EventGrid.subscribe(topic, :sub, sub4_pid)
    assert_receive {:got3, ^topic, "down-1"}, 2000
  end

  test "event grid: non-at-least-once delivery_mode typed-refused" do
    SmaltTest.Env.put_restored(event_grid: [delivery_mode: :at_most_once])
    topic = unique_topic()
    EventGrid.reset(topic)
    EventGrid.subscribe(topic, :sub)

    assert_raise ArgumentError, ~r/delivery_mode/, fn ->
      EventGrid.publish(topic, %{id: "m1"})
    end
  end

  # ===========================================================================
  # Harness
  # ===========================================================================

  defp unique_topic, do: :"eg-topic-#{System.unique_integer([:positive])}"

  defp hub_suffix(addr) do
    "it-hub-" <> rest = addr
    rest |> String.split("/") |> hd()
  end

  defp wire_conn! do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    accept_task =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listener, 5000)
        {:ok, pid} = Smalt.Amqp.Connection.start_link(socket: sock)
        :ok = :gen_tcp.controlling_process(sock, pid)
        {:ok, pid}
      end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
    {:ok, conn} = Task.await(accept_task, 5000)
    {client, conn}
  end

  defp handshake(client) do
    :ok = :gen_tcp.send(client, @sasl_header)
    assert {:ok, @sasl_header} = recv_exact(client, 8)
    recv_frame(client)

    :ok =
      :gen_tcp.send(client, FrameCodec.encode_frame(:sasl, 0, {:sasl_init, %{mechanism: "ANONYMOUS"}}))

    recv_frame(client)
    :ok = :gen_tcp.send(client, @header)
    assert {:ok, @header} = recv_exact(client, 8)

    :ok =
      :gen_tcp.send(
        client,
        FrameCodec.encode_frame(:amqp, 0, {:open, %{container_id: "azb07", max_frame_size: 65_536, channel_max: 65_535}})
      )

    recv_frame(client)

    :ok =
      :gen_tcp.send(
        client,
        FrameCodec.encode_frame(:amqp, 0, {:begin, %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}})
      )

    recv_frame(client)
    :ok
  end

  defp recv_until(client, name, timeout \\ 2000) do
    frame = recv_frame(client, timeout)

    if frame.performative.performative == name, do: frame, else: recv_until(client, name, timeout)
  end

  defp recv_frame(client, timeout \\ 2000) do
    frame = do_recv_frame(client, timeout)

    if frame.performative.performative == :flow,
      do: recv_frame(client, timeout),
      else: frame
  end

  defp do_recv_frame(client, timeout) do
    {:ok, hdr} = recv_exact(client, 8, timeout)
    <<size::unsigned-integer-size(32), _doff, _type, _channel::16>> = hdr
    body = elem(recv_exact(client, size - 8, timeout), 1)

    case FrameCodec.decode_frame(hdr <> body) do
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
end
