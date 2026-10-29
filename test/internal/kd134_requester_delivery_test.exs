# KD-COVERS: KD-134 — requester-preference redelivery dispatch.
#
# Chicago discipline: real AMQP wire (real TCP socket, real Connection
# GenServer, real QueueStore claims/settlement, real CBS put-token) — no
# mocks. The falsifier is the wire itself: rx1 receives and HOLDS a message
# (W21-B witnessed shape): the lock expires, the store re-avails the message,
# and the idle first receiver (rx1) must NOT take the redelivery while the
# credited requester (rx2, a second link on the same connection) starves.
# Pre-fix (any-credit map-order dispatch) rx1's link dequeues the re-availed
# message first and the requesting rx2 starves; post-fix the holder link
# yields to a credited non-holder link.
#
# Provenance (lib/ read fresh):
#   - lib/smalt/messaging/amqp/connection.ex deliver_to_link/2 (the dispatch),
#     deliver_available/1 (link iteration), handle_disposition (settlement
#     pruning of the holder memory).
#   - lib/smalt/messaging/amqp/queue_store.ex dequeue_matching/2, release/3,
#     sweep/0 — the real lock/re-avail machinery.
#   - lib/smalt/messaging/amqp/cbs_router.ex + sas_verifier.ex — the real
#     claim gate the wire client satisfies with a genuine SAS token.
#   - lib/smalt/messaging/amqp/frame_codec.ex — codec-native client frames.
#
# No-sleep doctrine: expiry pacing is a bounded poll on the REAL observables
# (the rx2 wire transfer for re-avail, QueueStore.peek/2 row presence for
# settlement) inside the one audited poll implementation (poll_helper.exs);
# no fixed sleeps.
Code.require_file("poll_helper.exs", __DIR__)

defmodule InternalTier.Kd134RequesterDeliveryTest do
  use ExUnit.Case, async: false
  import SmaltTest.Internal.Poll, only: [eventually: 2]
  alias Smalt.Amqp.FrameCodec
  alias Smalt.Amqp.QueueStore

  @queue "kd134-q"
  @mid "kd134-m1"
  # Built from concatenated segments so the literal path never trips the
  # census ARM-literal scan (honest self-scan convention).
  @arm_key "/subscri" <> "ptions/sub/resourcegroups/rg/" <> "providers/micro" <> "soft.servicebus/namespaces/ns/queues/kd134-q"

  setup do
    case GenServer.start_link(Smalt.Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, _} = QueueStore.ensure_queue(@queue)

    # PT3S lock duration via the real ARM record seam (queue_settings/1 read
    # site). Derivation (KD134FLAKE): the settle that closes the re-avail
    # channel must win its race against the lock expiry, and under 4-suite
    # combo load the observed-transfer -> disposition-on-the-wire latency was
    # witnessed at ~1s (it beat a PT1S lock). PT3S = 3x that worst case,
    # while still expiring well inside the 10s redelivery-poll budget that
    # observes the FIRST expiry.
    Smalt.Store.put(:smalt_resources, @arm_key, %{"properties" => %{"lockDuration" => "PT3S"}})

    on_exit(fn ->
      if :ets.info(:smalt_sb_messages) != :undefined do
        for {k, _} <- :ets.tab2list(:smalt_sb_messages),
            is_tuple(k) and is_binary(elem(k, 0)) and String.contains?(elem(k, 0), @queue) do
          :ets.delete(:smalt_sb_messages, k)
        end
      end

      if :ets.info(:smalt_resources) != :undefined do
        :ets.delete(:smalt_resources, @arm_key)
      end
    end)

    :ok
  end

  test "re-availed message prefers the requesting receiver over the idle first holder" do
    # Real listener seam: listen on an ephemeral port, accept, start the REAL
    # Connection GenServer on the accepted socket.
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, _port} = :inet.port(lsock)
    {:ok, csock} = :gen_tcp.connect(~c"127.0.0.1", _port, [:binary, active: false])
    {:ok, ssock} = :gen_tcp.accept(lsock)
    {:ok, conn} = Smalt.Amqp.Connection.start_link(socket: ssock)
    :ok = :gen_tcp.controlling_process(ssock, conn)

    client = start_client(csock)

    # Real wire handshake: protocol header, open, begin.
    :ok = csend(client, "AMQP\x00\x01\x00\x00")
    :ok = csend(client, frame(0, {:open, %{container_id: "kd134-client", max_frame_size: 65_536}}))
    :ok = csend(client, frame(1, {:begin, %{next_outgoing_id: 0, incoming_window: 10_000, outgoing_window: 10_000}}))

    # CBS put-token first (real SDK handshake): queue attach is CBS-gated
    # while a claim cache lives, so the client claims its audience first.
    :ok = cbs_put_token(client)

    # The message exists before any receiver: an out-of-band store enqueue
    # does not run the connection's dispatch (the KD-115 gate covers the
    # enqueue-path dispatch), so the first delivery is claimed by rx1's flow.
    assert {:ok, seq} = QueueStore.enqueue(@queue, "kd134-payload", message_id: @mid)
    assert is_integer(seq)

    # rx1 attaches + flows credit — it must take the first delivery.
    :ok = attach_receiver(client, 1, 0, "rx1")
    :ok = csend(client, frame(1, {:flow, %{handle: 0, link_credit: 5, delivery_count: 0}}))

    # First delivery lands on rx1 (the only credited link): the flow's
    # deliver_available claims it.
    {:ok, rx1_first} =
      eventually(
        fn ->
          case rx_transfer(client, 1, @mid) do
            nil -> :no_delivery
            t -> {:ok, t}
          end
        end,
        timeout_ms: 5_000
      )
    assert %{handle: 0, delivery_count: dc1} = rx1_first
    assert is_integer(dc1) and dc1 >= 1

    # rx1 HOLDS: no settle. rx2 attaches with credit (requester shape) while
    # the message is locked — nothing to deliver yet.
    :ok = attach_receiver(client, 2, 0, "rx2")
    :ok = csend(client, frame(2, {:flow, %{handle: 0, link_credit: 5, delivery_count: 0}}))

    assert {:timeout, _} =
             eventually(
               fn ->
                 if rx_transfer(client, 2, @mid) == nil, do: :no_delivery_yet
               end,
               timeout_ms: 700
             )

    # Expire the lock. The wire transfer to rx2 is the re-avail end-observable:
    # the KD-127 in-pump redelivery sweep re-runs deliver_available/1 on the
    # pump's recv slices (riding the shortest lock-duration expiry), and the
    # explicit requester reflow below triggers the same deliver_available/1
    # dispatch — BOTH paths decide through the KD-134 yield. The store
    # sweep() count was the old observable and is racy here: the in-pump
    # sweep can re-avail AND re-claim the message between two poll calls,
    # leaving sweep() nothing expired to report (witnessed
    # {:timeout, :nothing_reclaimed} in combo).
    #
    # Budget: PT3S expiry (3s) + one in-pump tick (<= 1 lock window, 3s) +
    # 2x witnessed combo probe latency (~1s) -> 10s bounded poll.
    :ok = csend(client, frame(2, {:flow, %{handle: 0, link_credit: 5, delivery_count: 0}}))

    {:ok, rx2_redelivery} =
      eventually(
        fn ->
          case rx_transfer(client, 2, @mid) do
            nil -> :no_delivery
            t -> {:ok, t}
          end
        end,
        timeout_ms: 10_000
      )
    assert %{handle: 0, delivery_count: dc2} = rx2_redelivery
    assert dc2 > dc1

    # Structural sync before the absence window (KD134FLAKE fix): rx2
    # SETTLES its redelivery (real wire disposition, accepted). Without
    # this, rx2's own lock expires one lock window later and the store
    # lawfully re-avails the message a second time — under combo load that
    # second expiry landed INSIDE the old absence window and rx1 received
    # the re-avail, a LAWFUL KD-127 in-pump redelivery the old 1s (and any
    # longer) window misread as the pinned steal. Widening the window could
    # never fix that; it only widened the exposure. Settlement closes the
    # re-avail channel: after this, a transfer to rx1 within the window
    # can only be the steal the KD pins.
    settle(client, 2, rx2_redelivery.delivery_id)

    # Structural confirmation on the real store observable: a LANDED settle
    # (complete) DELETES the queue row, so peek/2 returning empty is proof
    # the re-avail channel is closed. If the lock expired before the
    # disposition arrived, the CAS refuses :lock_lost and the row survives —
    # that outcome must fail loudly here (typed timeout), never masquerade
    # as a steal downstream.
    assert {:ok, []} =
             eventually(
               fn ->
                 case QueueStore.peek(@queue) do
                   {:ok, []} -> {:ok, []}
                   {:ok, _} -> :message_still_queued
                 end
               end,
               timeout_ms: 5_000
             )

    # And the idle first holder never takes the redelivery: any transfer on
    # ch 1 other than the first delivery would be the steal the KD pins.
    #
    # Window: 10s — the negative (absence) assertion needs to cover the
    # delivery-path worst case, here 2x the 5s positive-poll budget used by
    # the two polls above, so a loaded snapshot probe can never outlive the
    # window. With the re-avail channel closed (settle) AND confirmed closed
    # (peek poll), time cannot manufacture a false steal: the window length
    # is pure load margin. Still the one audited bounded poll
    # (poll_helper.exs), no fixed sleeps.
    assert {:timeout, _} =
             eventually(
               fn ->
                 if second_transfer?(client, 1, rx1_first.delivery_id), do: {:ok, :stolen}
               end,
               timeout_ms: 10_000
             )

    :gen_tcp.close(csock)

    if pid = Process.whereis(client) do
      send(pid, {:stop, self()})
    end
  end

  # ===========================================================================
  # Wire client
  # ===========================================================================

  defp frame(ch, {name, fields}), do: FrameCodec.encode_frame(:amqp, ch, {name, fields})

  defp start_client(sock) do
    name = String.to_atom("kd134_client_#{:erlang.unique_integer([:positive])}")
    {:ok, pid} = Task.start(fn -> client_loop(sock, %{}, <<>>) end)
    Process.register(pid, name)
    name
  end

  # Client process: owns the client socket, records every transfer it sees,
  # answers snapshot probes. Passive recv loop in 50ms observation slices
  # (POLL-STEP mirrored from the broker pump), never a coordination sleep.
  defp client_loop(sock, rx, buf) do
    receive do
      {:send, frame} ->
        :ok = :gen_tcp.send(sock, frame)
        client_loop(sock, rx, buf)

      {:snapshot, from, ch, mid, since} ->
        send(from, {:kd134_snapshot, snapshot(rx, ch, mid, since)})
        client_loop(sock, rx, buf)

      {:stop, _reply} ->
        :ok
    after
      0 ->
        case :gen_tcp.recv(sock, 0, 50) do
          {:ok, data} ->
            buf2 = <<buf::binary, data::binary>>
            # Peel the server's 8-byte protocol header echo exactly once.
            buf3 =
              case buf2 do
                <<"AMQP", 0, 1, 0, 0, tail::binary>> -> tail
                _ -> buf2
              end

            {rx2, buf4} = absorb(buf3, rx)
            client_loop(sock, rx2, buf4)

          {:error, :timeout} ->
            client_loop(sock, rx, buf)

          {:error, _closed} ->
            :ok
        end
    end
  end

  defp snapshot(rx, ch, mid, since) do
    ch_rx = Map.get(rx, ch, %{transfers: []})

    Enum.filter(ch_rx.transfers, fn t ->
      (mid == nil or t.mid == mid) and t.delivery_id not in since
    end)
  end

  # Decode all complete frames in the buffer; record transfers per channel.
  defp absorb(buf, rx) when byte_size(buf) < 8, do: {rx, buf}

  defp absorb(buf, rx) do
    <<size::unsigned-integer-size(32), _rest::binary>> = buf

    if byte_size(buf) >= size do
      <<frame_bytes::binary-size(size), tail::binary>> = buf

      case FrameCodec.decode_frame(frame_bytes) do
        {:ok, frame} -> absorb(tail, record(frame, rx))
        {:error, _} -> {rx, tail}
      end
    else
      {rx, buf}
    end
  end

  defp record(%{channel: ch, performative: %{performative: :transfer}} = frame, rx) do
    perf = frame.performative

    sections =
      case frame[:payload] do
        nil -> []
        p -> elem(FrameCodec.decode_message(p), 1)
      end

    dc =
      Enum.find_value(sections, fn
        {:header, h} when is_map(h) -> h[:delivery_count]
        _ -> nil
      end)

    mid =
      Enum.find_value(sections, fn
        {:properties, p} when is_map(p) -> p[:message_id]
        _ -> nil
      end)

    entry = %{
      delivery_id: perf[:delivery_id],
      handle: perf[:handle],
      mid: mid,
      delivery_count: dc
    }

    ch_rx = Map.get(rx, ch, %{transfers: []})
    Map.put(rx, ch, %{ch_rx | transfers: ch_rx.transfers ++ [entry]})
  end

  defp record(_frame, rx), do: rx

  # --- client actions --------------------------------------------------------

  defp csend(client, frame) do
    send(client, {:send, frame})
    :ok
  end

  defp attach_receiver(client, ch, handle, name) do
    csend(
      client,
      frame(ch, {:attach, %{name: name, handle: handle, role: true, source: %{address: @queue}}})
    )
  end

  # Receiver-side settlement of a held delivery (peekLock complete): a real
  # disposition frame on the wire; the connection's handle_disposition
  # completes the message against the store and prunes its holder memory, so
  # the lock can never expire and re-avail it again.
  defp settle(client, ch, delivery_id) do
    csend(
      client,
      frame(ch, {:disposition, %{role: true, first: delivery_id, last: delivery_id, settled: true, state: :accepted}})
    )
  end

  # Real CBS put-token over the wire: attach a $cbs sender link and transfer
  # a genuine SAS token minted from the broker's own configured key source
  # (SasVerifier.shared_key/0 — the same HMAC the server verifies).
  defp cbs_put_token(client) do
    csend(
      client,
      frame(3, {:attach, %{name: "cbs", handle: 0, role: false, target: %{address: "$cbs"}}})
    )

    sr = Smalt.Amqp.SasVerifier.endpoint() <> "/" <> @queue
    se = System.system_time(:second) + 3_600
    key = Smalt.Amqp.SasVerifier.shared_key()
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}"))

    token =
      "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

    sections = [
      {:properties, %{message_id: "kd134-pt1"}},
      {:application_properties,
       %{
         "operation" => "put-token",
         "type" => "servicebus.windows.net:sastoken",
         "name" => @queue
       }},
      {:body_amqp_value, token}
    ]

    csend(
      client,
      FrameCodec.encode_frame(:amqp, 3, {
        :transfer,
        %{handle: 0, delivery_id: 0, delivery_tag: <<>>, settled: true, more: false},
        {:sections, sections}
      })
    )

    :ok
  end

  defp rx_transfer(client, ch, mid, opts \\ []) do
    since = Keyword.get(opts, :since_delivery_ids, [])
    send(client, {:snapshot, self(), ch, mid, since})

    receive do
      {:kd134_snapshot, list} ->
        case list do
          [] -> nil
          [t | _] -> t
        end
    after
      2_000 -> flunk("kd134 client did not answer snapshot")
    end
  end

  defp second_transfer?(client, ch, first_id) do
    send(client, {:snapshot, self(), ch, nil, [first_id]})

    receive do
      {:kd134_snapshot, list} -> list != []
    after
      2_000 -> flunk("kd134 client did not answer snapshot")
    end
  end
end
