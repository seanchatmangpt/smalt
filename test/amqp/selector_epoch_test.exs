defmodule Smalt.Amqp.SelectorEpochTest do
  @moduledoc """
  GAP-A2-01 / GAP-A2-02 falsifier courts (lane W-1, v26.10.14).

  KD-68: EH `apache.org:selector-filter:string` source filter (eventPosition)
  must be decoded and honored as the receive start cursor — attach with an
  offset filter and assert the FIRST delivered event honors it (pre-fix the
  link delivered from cursor 0 unconditionally).

  KD-69: `com.microsoft:epoch` exclusive receiver must be enforced — a second
  attach with equal-or-higher epoch evicts the older link (typed detach),
  a lower epoch is refused. Pre-fix, two epoch receivers both received.
  """

  use ExUnit.Case, async: false
  @moduletag :amqp_wire

  alias Smalt.Amqp.FrameCodec

  @epoch_evict_condition "com.microsoft:epoch-lock-lost"

  setup do
    SmaltTest.Env.put_restored(sb_shared_key: "test-shared-key-0123456789abcdef012345")

    if GenServer.whereis(Smalt.Store) == nil do
      start_supervised!(Smalt.Store)
    end

    Smalt.Messaging.EventHubs.ensure_tables()

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)

    accept_task =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listener, 5000)
        {:ok, pid} = Smalt.Amqp.Connection.start_link(socket: sock)
        :ok = :gen_tcp.controlling_process(sock, pid)
        {:ok, pid}
      end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
    {:ok, _conn} = Task.await(accept_task, 5000)

    eh_address =
      "/eventhubs/sep-hub-" <>
        "#{System.unique_integer([:positive])}" <> "/partitions/0"

    %{client: client, eh_address: eh_address}
  end

  # ---------------------------------------------------------------------------
  # GAP-A2-01 (KD-68): selector filter -> receive start cursor
  # ---------------------------------------------------------------------------
  describe "GAP-A2-01 selector filter" do
    @tag :amqp_wire
    test "attach with offset filter delivers first event AFTER the offset", %{
      client: client,
      eh_address: eh_address
    } do
      wh(client)

      # send 3 events
      {:ok, s} = attach_sender(client, eh_address)

      for i <- 1..3 do
        send_event(client, s, i)

        assert %{performative: %{settled: true, state: :accepted}} =
                 recv_until(client, :disposition)
      end

      # receiver with x-opt-offset > '1' -> first delivery must be seq 2
      selector = "amqp.annotation.x-opt-offset > '1'"

      :ok =
        send_b(
          client,
          enc(
            :amqp,
            0,
            {:attach,
             %{
               name: "eh-r",
               handle: 1,
               role: true,
               source: source_with_selector(eh_address, selector)
             }}
          )
        )

      assert %{performative: %{performative: :attach}} = recv_f(client)

      :ok = send_b(client, enc(:amqp, 0, {:flow, %{handle: 1, link_credit: 10}}))

      transfers = drain_transfers(client)

      seqs = Enum.map(transfers, &transfer_seq/1)

      # falsifier: pre-fix the first delivered x-opt-sequence-number was 1
      assert seqs != [] and hd(seqs) == 2 and seqs == [2, 3]
    end

    @tag :amqp_wire
    test "sequence-number filter starts at the given sequence", %{
      client: client,
      eh_address: eh_address
    } do
      wh(client)
      {:ok, s} = attach_sender(client, eh_address)

      for i <- 1..3 do
        send_event(client, s, i)

        assert %{performative: %{settled: true, state: :accepted}} =
                 recv_until(client, :disposition)
      end

      selector = "amqp.annotation.x-opt-sequence-number > '2'"

      :ok =
        send_b(
          client,
          enc(
            :amqp,
            0,
            {:attach,
             %{
               name: "eh-r",
               handle: 1,
               role: true,
               source: source_with_selector(eh_address, selector)
             }}
          )
        )

      assert %{performative: %{performative: :attach}} = recv_f(client)
      :ok = send_b(client, enc(:amqp, 0, {:flow, %{handle: 1, link_credit: 10}}))

      assert drain_transfers(client) |> Enum.map(&transfer_seq/1) == [3]
    end

    @tag :amqp_wire
    test "inclusive >= selector (SDK startingPosition isInclusive) starts AT n", %{
      client: client,
      eh_address: eh_address
    } do
      wh(client)
      {:ok, s} = attach_sender(client, eh_address)

      for i <- 1..3 do
        send_event(client, s, i)

        assert %{performative: %{settled: true, state: :accepted}} =
                 recv_until(client, :disposition)
      end

      # r200c falsifier shape: 6.x SDK startingPosition {sequenceNumber: 2,
      # isInclusive: true} -> wire clause with >= (the old exclusive-only
      # regex dropped it and the link delivered from cursor 0).
      selector = "amqp.annotation.x-opt-sequence-number >= '2'"

      :ok =
        send_b(
          client,
          enc(
            :amqp,
            0,
            {:attach,
             %{
               name: "eh-r",
               handle: 1,
               role: true,
               source: source_with_selector(eh_address, selector)
             }}
          )
        )

      assert %{performative: %{performative: :attach}} = recv_f(client)
      :ok = send_b(client, enc(:amqp, 0, {:flow, %{handle: 1, link_credit: 10}}))

      seqs = drain_transfers(client) |> Enum.map(&transfer_seq/1)

      assert seqs != [] and hd(seqs) == 2 and seqs == [2, 3]
    end

    @tag :amqp_wire
    test "unsupported selector detaches typed instead of passing through", %{
      client: client,
      eh_address: eh_address
    } do
      wh(client)
      {:ok, s} = attach_sender(client, eh_address)

      for i <- 1..2 do
        send_event(client, s, i)

        assert %{performative: %{settled: true, state: :accepted}} =
                 recv_until(client, :disposition)
      end

      # Free-form SQL-ish selector is not one of the eventPosition forms the
      # broker honors -> typed detach, NEVER unfiltered delivery.
      selector = "amqp.annotation.x-opt-sequence-number > '1' AND body LIKE '%x%'"

      :ok =
        send_b(
          client,
          enc(
            :amqp,
            0,
            {:attach,
             %{
               name: "eh-r",
               handle: 1,
               role: true,
               source: source_with_selector(eh_address, selector)
             }}
          )
        )

      assert %{performative: %{performative: :attach}} = recv_f(client)

      detach = recv_until(client, :detach)

      assert %{performative: %{error: err}} = detach
      assert error_condition(err) == "amqp:not-implemented"
      assert error_description(err) =~ "SELECTOR_UNSUPPORTED"

      # no transfers may arrive on the refused handle
      :ok = send_b(client, enc(:amqp, 0, {:flow, %{handle: 1, link_credit: 10}}))
      assert :timeout = recv_f_safe(client, 300)
    end

    @tag :amqp_wire
    test "enqueued-time filter drops older events", %{
      client: client,
      eh_address: eh_address
    } do
      wh(client)
      {:ok, s} = attach_sender(client, eh_address)

      # event 1 in the past, event 2 now
      now = System.system_time(:millisecond)

      :ok =
        send_b(
          client,
          enc(
            :amqp,
            0,
            {:transfer,
             %{
               handle: s,
               delivery_id: 1,
               delivery_tag: <<1::8>>,
               message_format: 0,
               settled: true,
               more: false
             }, {:sections, [{:body_data, "old-event"}]}}
          )
        )

      assert %{performative: %{settled: true, state: :accepted}} =
               recv_until(client, :disposition)

      # rewind its enqueued time directly in the partition row
      # (key mirrors Connection.eh_partition/1: hub-scoped, not last segment)
      partition =
        case String.split(eh_address, "/eventhubs/") do
          [_, rest] -> String.replace_leading(rest, "/", "")
          _ -> eh_address |> String.split("/") |> List.last()
        end

      [{^partition, row}] = :ets.lookup(:smalt_eh_partitions, partition)
      [{seq1, {body, props, meta}} | rest] = row["events"]

      :ets.insert(
        :smalt_eh_partitions,
        {partition,
         %{
           row
           | "events" => [
               {seq1, {body, props, Map.put(meta, "enqueued_ms", now - 60_000)}} | rest
             ]
         }}
      )

      send_event(client, s, 2)

      assert %{performative: %{settled: true, state: :accepted}} =
               recv_until(client, :disposition)

      selector = "amqp.annotation.x-opt-enqueued-time > '#{now - 30_000}'"

      :ok =
        send_b(
          client,
          enc(
            :amqp,
            0,
            {:attach,
             %{
               name: "eh-r",
               handle: 1,
               role: true,
               source: source_with_selector(eh_address, selector)
             }}
          )
        )

      assert %{performative: %{performative: :attach}} = recv_f(client)
      :ok = send_b(client, enc(:amqp, 0, {:flow, %{handle: 1, link_credit: 10}}))

      bodies =
        drain_transfers(client)
        |> Enum.map(fn tr ->
          {:ok, sections} = FrameCodec.decode_message(tr.payload)

          Enum.find_value(sections, fn
            {:body_data, b} -> b
            _ -> nil
          end)
        end)

      assert bodies == ["eh-event-2"]
    end
  end

  # ---------------------------------------------------------------------------
  # GAP-A2-02 (KD-69): epoch exclusivity
  # ---------------------------------------------------------------------------
  describe "GAP-A2-02 epoch exclusivity" do
    @tag :amqp_wire
    test "higher epoch evicts the older link with a typed detach", %{
      client: client,
      eh_address: eh_address
    } do
      wh(client)
      {:ok, s} = attach_sender(client, eh_address)

      for i <- 1..2 do
        send_event(client, s, i)

        assert %{performative: %{settled: true, state: :accepted}} =
                 recv_until(client, :disposition)
      end

      # epoch-1 receiver on handle 1
      :ok =
        send_b(
          client,
          enc(
            :amqp,
            0,
            {:attach,
             %{
               name: "r-e1",
               handle: 1,
               role: true,
               source: %{address: eh_address},
               properties: %{"com.microsoft:epoch" => 1}
             }}
          )
        )

      assert %{performative: %{performative: :attach}} = recv_f(client)

      # epoch-2 receiver on handle 2 evicts handle 1
      :ok =
        send_b(
          client,
          enc(
            :amqp,
            0,
            {:attach,
             %{
               name: "r-e2",
               handle: 2,
               role: true,
               source: %{address: eh_address},
               properties: %{"com.microsoft:epoch" => 2}
             }}
          )
        )

      attach_echo = recv_f(client)
      assert %{performative: %{performative: :attach}} = attach_echo

      evict = recv_until(client, :detach, 3000)
      assert evict.performative.handle == 1
      assert evict.performative.closed == true
      assert error_condition(evict.performative.error) == @epoch_evict_condition

      # the surviving link delivers; the evicted one must not
      :ok = send_b(client, enc(:amqp, 0, {:flow, %{handle: 2, link_credit: 10}}))

      seqs = drain_transfers(client) |> Enum.map(&transfer_seq/1)
      assert seqs == [1, 2]
    end

    @tag :amqp_wire
    test "lower epoch is refused with a typed detach on the NEW handle", %{
      client: client,
      eh_address: eh_address
    } do
      wh(client)

      # epoch 2 first
      :ok =
        send_b(
          client,
          enc(
            :amqp,
            0,
            {:attach,
             %{
               name: "r-e2",
               handle: 1,
               role: true,
               source: %{address: eh_address},
               properties: %{"com.microsoft:epoch" => 2}
             }}
          )
        )

      assert %{performative: %{performative: :attach}} = recv_f(client)

      # epoch 1 attach refused: attach echo then typed detach on handle 2
      :ok =
        send_b(
          client,
          enc(
            :amqp,
            0,
            {:attach,
             %{
               name: "r-e1",
               handle: 2,
               role: true,
               source: %{address: eh_address},
               properties: %{"com.microsoft:epoch" => 1}
             }}
          )
        )

      assert %{performative: %{performative: :attach}} = recv_f(client)

      refused = recv_until(client, :detach, 3000)
      assert refused.performative.handle == 2
      assert error_condition(refused.performative.error) == @epoch_evict_condition
    end

    @tag :amqp_wire
    test "client detach of the epoch holder releases the registration", %{
      client: client,
      eh_address: eh_address
    } do
      wh(client)

      :ok =
        send_b(
          client,
          enc(
            :amqp,
            0,
            {:attach,
             %{
               name: "r-e1",
               handle: 1,
               role: true,
               source: %{address: eh_address},
               properties: %{"com.microsoft:epoch" => 1}
             }}
          )
        )

      assert %{performative: %{performative: :attach}} = recv_f(client)

      :ok = send_b(client, enc(:amqp, 0, {:detach, %{handle: 1, closed: true}}))
      assert %{performative: %{performative: :detach}} = recv_f(client)

      # the same epoch must now be re-admittable on a fresh handle
      :ok =
        send_b(
          client,
          enc(
            :amqp,
            0,
            {:attach,
             %{
               name: "r-e1b",
               handle: 2,
               role: true,
               source: %{address: eh_address},
               properties: %{"com.microsoft:epoch" => 1}
             }}
          )
        )

      assert %{performative: %{performative: :attach}} = recv_f(client)
      # no detach follows
      assert {:error, :timeout} = try_recv(client)
    end
  end

  # ---------------------------------------------------------------------------
  # Harness (mirrors test/amqp/event_hubs_test.exs)
  # ---------------------------------------------------------------------------

  defp wh(client) do
    :ok = :gen_tcp.send(client, "AMQP\x03\x01\x00\x00")
    assert {:ok, "AMQP\x03\x01\x00\x00"} = rx(client, 8)
    _mech = recv_f(client)
    :ok = send_b(client, enc(:sasl, 0, {:sasl_init, %{mechanism: "ANONYMOUS"}}))
    _outcome = recv_f(client)
    :ok = :gen_tcp.send(client, "AMQP\x00\x01\x00\x00")
    assert {:ok, "AMQP\x00\x01\x00\x00"} = rx(client, 8)

    :ok =
      send_b(
        client,
        enc(
          :amqp,
          0,
          {:open, %{container_id: "sep-test-client", max_frame_size: 65_536, channel_max: 65_535}}
        )
      )

    _opened = recv_f(client)

    :ok =
      send_b(
        client,
        enc(
          :amqp,
          0,
          {:begin,
           %{
             next_outgoing_id: 1,
             incoming_window: 10_000,
             outgoing_window: 10_000,
             handle_max: 100
           }}
        )
      )

    _begun = recv_f(client)
    :ok
  end

  defp attach_sender(client, address) do
    :ok =
      send_b(
        client,
        enc(
          :amqp,
          0,
          {:attach, %{name: "eh-s", handle: 0, role: false, target: %{address: address}}}
        )
      )

    assert %{performative: %{performative: :attach}} = recv_f(client)
    {:ok, 0}
  end

  defp send_event(client, sender_handle, i) do
    :ok =
      send_b(
        client,
        enc(
          :amqp,
          0,
          {:transfer,
           %{
             handle: sender_handle,
             delivery_id: i,
             delivery_tag: <<i::8>>,
             message_format: 0,
             settled: true,
             more: false
           }, {:sections, [{:body_data, "eh-event-#{i}"}]}}
        )
      )
  end

  defp source_with_selector(address, clause) do
    %{
      address: address,
      filter: %{"apache.org:selector-filter:string" => {:selector_filter, clause}}
    }
  end

  defp drain_transfers(client) do
    case try_recv(client) do
      {:ok, %{performative: %{performative: :transfer}} = tr} -> [tr | drain_transfers(client)]
      _ -> []
    end
  end

  defp transfer_seq(tr) do
    {:ok, sections} = FrameCodec.decode_message(tr.payload)

    Enum.find_value(sections, fn
      {:message_annotations, %{"x-opt-sequence-number" => seq}} -> seq
      _ -> nil
    end)
  end

  defp try_recv(client, timeout \\ 400) do
    case recv_f_safe(client, timeout) do
      {:ok, frame} -> {:ok, frame}
      :timeout -> {:error, :timeout}
    end
  end

  defp recv_f_safe(client, timeout) do
    case rx(client, 8, timeout) do
      {:ok, <<>>} ->
        :timeout

      {:ok, hdr} ->
        <<size::unsigned-integer-size(32), _doff, _type, _ch::16>> = hdr
        body = elem(rx(client, size - 8, timeout), 1)

        case FrameCodec.decode_frame(hdr <> body) do
          {:ok, frame} -> {:ok, frame}
          other -> flunk("frame decode failed: #{inspect(other)}")
        end
    end
  end

  # FrameCodec decodes the detach error as the wire's positional composite
  # [condition(symbol), description, info] (same contract as
  # connection_test.exs error_condition/1), not a map.
  defp error_condition([{:symbol, c} | _]) when is_binary(c), do: c
  defp error_condition(%{condition: c}) when is_binary(c), do: c

  defp error_description([{:symbol, _}, d | _]) when is_binary(d), do: d
  defp error_description(%{description: d}) when is_binary(d), do: d

  defp enc(layer, channel, performative),
    do: Smalt.Amqp.FrameCodec.encode_frame(layer, channel, performative)

  defp send_b(client, iodata), do: :gen_tcp.send(client, iodata)

  defp recv_f(client, timeout \\ 2000) do
    {:ok, hdr} = rx(client, 8, timeout)
    <<size::unsigned-integer-size(32), _doff, _type, _ch::16>> = hdr
    body = elem(rx(client, size - 8, timeout), 1)

    case FrameCodec.decode_frame(hdr <> body) do
      {:ok, frame} -> frame
      other -> flunk("frame decode failed: #{inspect(other)}")
    end
  end

  defp recv_until(client, name, timeout \\ 2000) do
    frame = recv_f(client, timeout)

    if frame.performative.performative == name,
      do: frame,
      else: recv_until(client, name, timeout)
  end

  defp rx(client, n, timeout \\ 2000)

  defp rx(_client, 0, _timeout), do: {:ok, <<>>}

  # A recv timeout is the normal drain-termination signal (the link stays
  # open); map it to the empty-binary sentinel recv_f_safe already treats as
  # :timeout. Without this clause rx raised CaseClauseError on every drain
  # that ended in silence (R69).
  defp rx(client, n, timeout) do
    case :gen_tcp.recv(client, n, timeout) do
      {:ok, data} -> {:ok, data}
      {:error, :closed} -> {:ok, <<>>}
      {:error, :timeout} -> {:ok, <<>>}
    end
  end
end
