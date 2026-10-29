# T-12 — chaos injector court (docs/jira/v26.10.28/tickets/T12-amqp-chaos-injectors.md).
#
# Two tiers:
#
#   1. Pure-function courts over `Smalt.Messaging.Chaos` — typed boot-eval
#      config resolution (fail-closed on garbage), the detach predicate firing
#      EXACTLY on the Nth delivery and never before, starve off = always
#      false, session-timeout bounds (per namespace + the shared shortest
#      bound), and the retryable detach error shape.
#
#   2. Application.put_env round-trips THROUGH the real Connection hook paths
#      in-process (feasible, so no harness note deferral): real TCP socket,
#      real Connection GenServer, real QueueStore/EventHubs stores, real CBS
#      put-token, codec-native frames — the kd134 wire-client pattern. Each
#      leg arms a flag via put_env (the boot-eval form), observes the typed
#      fault on the wire + typed telemetry, then observes RECOVERY when the
#      flag clears.
#
# Anti-vacuity witness (the ticket's non-vacuity court): with every flag
# off, the same wire traffic delivers normally with NO detach, NO forced
# session end, and NO chaos telemetry.
#
# No Process.sleep anywhere: pacing is the one audited bounded poll
# (poll_helper.exs); the session-timeout court observes the broker's own
# Process.send_after timer (doctrine Law 2 scheduling, not a sleep).
Code.require_file("poll_helper.exs", Path.join(__DIR__, "../internal"))

defmodule Smalt.Integration.ChaosInjectorsTest do
  use ExUnit.Case, async: false
  import SmaltTest.Internal.Poll, only: [eventually: 2]

  alias Smalt.Amqp.FrameCodec
  alias Smalt.Amqp.QueueStore
  alias Smalt.Messaging.Chaos
  alias Smalt.Messaging.EventHubs

  @q_starve "chaos-starve-q"
  @q_detach "chaos-detach-q"
  @q_off "chaos-off-q"
  @q_eh "chaos-eh-q"
  # Unique per run so leftover events from earlier runs can never deliver.
  @eh_hub "chaos-hub-#{:erlang.unique_integer([:positive])}"

  @flags [
    :sb_chaos_detach_after,
    :sb_chaos_starve_credits,
    :sb_chaos_session_timeout_ms,
    :eh_chaos_detach_after,
    :eh_chaos_starve_credits,
    :eh_chaos_session_timeout_ms
  ]

  setup do
    case GenServer.start_link(Smalt.Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    prev = Map.new(@flags, &{&1, Application.get_env(:smalt, &1)})

    # Boot-eval discipline: every court boots from a flags-OFF substrate.
    for f <- @flags, do: Application.put_env(:smalt, f, nil)

    on_exit(fn ->
      for {f, v} <- prev, do: Application.put_env(:smalt, f, v)
      Enum.each([@q_starve, @q_detach, @q_off, @q_eh], &cleanup_queue_rows/1)
    end)

    :ok
  end

  # ===========================================================================
  # Pure courts over Smalt.Messaging.Chaos
  # ===========================================================================

  test "detach court: fires exactly on the Nth delivery, never before; off = never; garbage fails closed" do
    Application.put_env(:smalt, :sb_chaos_detach_after, 3)
    assert Chaos.detach_armed?(:sb)
    refute Chaos.should_detach?(1, :sb)
    refute Chaos.should_detach?(2, :sb)
    assert Chaos.should_detach?(3, :sb)
    # Liveness past N: a link that missed the exact count still detaches.
    assert Chaos.should_detach?(4, :sb)

    # Typed resolution fails closed: anything that is not a positive integer
    # reads as :infinity (injector off).
    Application.put_env(:smalt, :sb_chaos_detach_after, 0)
    assert Chaos.detach_after(:sb) == :infinity
    refute Chaos.should_detach?(3, :sb)
    refute Chaos.detach_armed?(:sb)

    Application.put_env(:smalt, :sb_chaos_detach_after, -2)
    assert Chaos.detach_after(:sb) == :infinity

    Application.put_env(:smalt, :sb_chaos_detach_after, "three")
    assert Chaos.detach_after(:sb) == :infinity

    # The EH namespace is its own flag over the shared machinery.
    Application.put_env(:smalt, :eh_chaos_detach_after, 2)
    assert Chaos.should_detach?(2, :eh)
    assert Chaos.detach_after(:sb) == :infinity
  end

  test "starve court: off = always false; on = withheld; namespaces isolated" do
    refute Chaos.starve?(:sb)
    refute Chaos.starve?(:eh)

    Application.put_env(:smalt, :sb_chaos_starve_credits, true)
    assert Chaos.starve?(:sb)
    refute Chaos.starve?(:eh)

    Application.put_env(:smalt, :sb_chaos_starve_credits, "off")
    refute Chaos.starve?(:sb)

    Application.put_env(:smalt, :eh_chaos_starve_credits, "on")
    assert Chaos.starve?(:eh)
    refute Chaos.starve?(:sb)
  end

  test "session timeout court: defaults :infinity; per-namespace bounds; shared bound = shortest armed" do
    assert Chaos.session_timeout(:sb) == :infinity
    assert Chaos.session_timeout(:eh) == :infinity
    assert Chaos.session_close_bound() == :infinity

    Application.put_env(:smalt, :sb_chaos_session_timeout_ms, 5_000)
    Application.put_env(:smalt, :eh_chaos_session_timeout_ms, 1_234)
    assert Chaos.session_timeout(:sb) == 5_000
    assert Chaos.session_timeout(:eh) == 1_234
    assert Chaos.session_close_bound() == 1_234

    # Garbage bounds fail closed to :infinity and drop out of the shared min.
    Application.put_env(:smalt, :eh_chaos_session_timeout_ms, 0)
    assert Chaos.session_timeout(:eh) == :infinity
    assert Chaos.session_close_bound() == 5_000
  end

  test "retryable detach error shape + config/0 round-trip" do
    err = Chaos.detach_error(7)
    assert err.condition == "amqp:link:detach-forced"
    assert err.description =~ "SMALT_CHAOS_DETACH_FORCED"
    assert err.description =~ "7"

    Application.put_env(:smalt, :sb_chaos_detach_after, 9)
    Application.put_env(:smalt, :sb_chaos_starve_credits, true)
    Application.put_env(:smalt, :sb_chaos_session_timeout_ms, 4_044)

    assert Chaos.config()[:sb] == %{
             detach_after: 9,
             starve_credits: true,
             session_timeout_ms: 4_044
           }

    assert Chaos.config()[:eh] == %{
             detach_after: :infinity,
             starve_credits: false,
             session_timeout_ms: :infinity
           }
  end

  # ===========================================================================
  # Wire round-trip: :sb_chaos_starve_credits
  # ===========================================================================

  test "credit starvation withholds deliveries until the flag clears (recovery receipt)" do
    Application.put_env(:smalt, :sb_chaos_starve_credits, true)
    tid = attach_chaos_telemetry()
    {:ok, _} = QueueStore.ensure_queue(@q_starve)
    {:ok, _} = QueueStore.enqueue(@q_starve, "chaos-starve-payload", message_id: "chaos-starve-m1")

    {client, csock} = start_connection()
    begin_session(client, 1)
    cbs_put_token(client, @q_starve)
    attach_receiver(client, 1, 0, "chaos-starve-rx", @q_starve)
    flow_credit(client, 1, 0, 5)

    # While armed, the flow's credit grant is withheld: NO transfer lands.
    assert {:timeout, _} =
             eventually(
               fn ->
                 if transfer_count(client, 1) > 0, do: {:ok, :delivered_while_starved}
               end,
               timeout_ms: 3_000
             )

    # The absence window doubles as the structural sync: the withheld grant's
    # typed telemetry is already in our mailbox by the time the window closes.
    events = drain_chaos_telemetry()

    assert Enum.any?(events, fn {ev, m, md} ->
             ev == :credit_starved and m.withheld_credit > 0 and md.namespace == :sb
           end)

    # Flip the flag off (the boot-eval form of "flip the flag off and
    # re-boot") and re-flow: the delivery lands with no other change.
    Application.put_env(:smalt, :sb_chaos_starve_credits, nil)
    flow_credit(client, 1, 0, 5)

    assert {:ok, _} =
             eventually(
               fn ->
                 if transfer_count(client, 1) > 0, do: {:ok, :delivered}
               end,
               timeout_ms: 5_000
             )

    # Starvation never detaches or ends anything: the link survives.
    refute Enum.any?(frames(client, 1), &(&1.kind in [:detach, :end]))

    :telemetry.detach(tid)
    stop(client, csock)
  end

  # ===========================================================================
  # Wire round-trip: :sb_chaos_detach_after
  # ===========================================================================

  test "detach-after-N detaches after exactly N deliveries (never before) and the relink recovers" do
    Application.put_env(:smalt, :sb_chaos_detach_after, 2)
    tid = attach_chaos_telemetry()
    {:ok, _} = QueueStore.ensure_queue(@q_detach)

    for i <- 1..3 do
      {:ok, _} = QueueStore.enqueue(@q_detach, "chaos-detach-payload-#{i}", message_id: "chaos-detach-m#{i}")
    end

    {client, csock} = start_connection()
    begin_session(client, 1)
    cbs_put_token(client, @q_detach)
    attach_receiver(client, 1, 0, "chaos-detach-rx", @q_detach)
    flow_credit(client, 1, 0, 10)

    # Two deliveries (the Nth, N=2) ...
    assert {:ok, _} =
             eventually(
               fn ->
                 if transfer_count(client, 1) >= 2, do: {:ok, :two_deliveries}
               end,
               timeout_ms: 5_000
             )

    # ... then the retryable forced detach, with the exact Azure-maintenance
    # error name and the chaos marker in the description.
    assert {:ok, conds} =
             eventually(
               fn ->
                 case detach_texts(client, 1) do
                   [] -> :no_detach
                   texts -> {:ok, texts}
                 end
               end,
               timeout_ms: 5_000
             )

    assert "amqp:link:detach-forced" in conds
    assert Enum.any?(conds, &String.contains?(&1, "SMALT_CHAOS_DETACH_FORCED"))

    # NEVER BEFORE: exactly N transfers preceded the first detach frame, and
    # the detach index sits after the SECOND transfer's index.
    chronological = frames(client, 1)

    transfer_indices =
      chronological
      |> Enum.with_index()
      |> Enum.filter(fn {f, _i} -> f.kind == :transfer end)
      |> Enum.map(fn {_f, i} -> i end)

    first_detach_idx = Enum.find_index(chronological, &(&1.kind == :detach))
    assert first_detach_idx > Enum.at(transfer_indices, 1)
    assert Enum.count(chronological, &(&1.kind == :transfer)) == 2

    # Typed telemetry for the fired injection.
    events = drain_chaos_telemetry()

    assert Enum.any?(events, fn {ev, m, md} ->
             ev == :link_detach and m.deliveries == 2 and md.namespace == :sb
           end)

    # Recovery receipt: the client relinks (new handle) + flows — the next
    # message lands with no client code change (and detaches again: every
    # N-th delivery, deterministically).
    attach_receiver(client, 1, 1, "chaos-detach-rx2", @q_detach)
    flow_credit(client, 1, 1, 10)

    assert {:ok, _} =
             eventually(
               fn ->
                 if transfer_count(client, 1) >= 3, do: {:ok, :third_delivery}
               end,
               timeout_ms: 5_000
             )

    assert {:ok, _} =
             eventually(
               fn ->
                 if length(detach_texts(client, 1)) >= 2, do: {:ok, :second_detach}
               end,
               timeout_ms: 5_000
             )

    :telemetry.detach(tid)
    stop(client, csock)
  end

  # ===========================================================================
  # Wire round-trip: :sb_chaos_session_timeout_ms
  # ===========================================================================

  test "session timeout closes the session typed at the injected deadline; re-begin recovers" do
    Application.put_env(:smalt, :sb_chaos_session_timeout_ms, 300)
    tid = attach_chaos_telemetry()

    {client, csock} = start_connection()
    begin_session(client, 1)

    # The broker's own send_after timer fires ~300ms in: the session closes
    # with a typed error carrying the chaos marker.
    assert {:ok, texts} =
             eventually(
               fn ->
                 case end_error_texts(client, 1) do
                   [] -> :no_end
                   texts -> {:ok, texts}
                 end
               end,
               timeout_ms: 5_000
             )

    assert Enum.any?(texts, &String.contains?(&1, "SMALT_CHAOS_SESSION_TIMEOUT"))

    events = drain_chaos_telemetry()
    assert Enum.any?(events, fn {ev, _, _} -> ev == :session_timeout end)

    # Client resiliency path: re-begin on the same channel recreates the
    # session (fresh begin reply — counted, so the first begin's echo cannot
    # satisfy this), and the injector re-arms deterministically.
    begin_session(client, 1)

    assert {:ok, _} =
             eventually(
               fn ->
                 if Enum.count(frames(client, 1), &(&1.kind == :begin)) >= 2,
                   do: {:ok, :rebegun}
               end,
               timeout_ms: 5_000
             )

    assert {:ok, _} =
             eventually(
               fn ->
                 if length(end_error_texts(client, 1)) >= 2, do: {:ok, :rearmed_and_closed}
               end,
               timeout_ms: 5_000
             )

    :telemetry.detach(tid)
    stop(client, csock)
  end

  # ===========================================================================
  # Wire round-trip: the :eh_* namespaced trio (shared machinery, link-kind
  # namespace resolution at the hook site)
  # ===========================================================================

  test "eh_chaos_starve_credits starves Event Hubs links while queue links deliver unaffected" do
    Application.put_env(:smalt, :eh_chaos_starve_credits, true)
    tid = attach_chaos_telemetry()
    EventHubs.ensure_tables()
    {:ok, _, _} = EventHubs.send_event("#{@eh_hub}/partitions/0", "chaos-eh-payload")
    {:ok, _} = QueueStore.ensure_queue(@q_eh)
    {:ok, _} = QueueStore.enqueue(@q_eh, "chaos-eh-q-payload", message_id: "chaos-eh-q-m1")

    # NOTE: on a :sb-mode connection the /eventhubs/ address form routes the
    # EH link (route/2) while the bare queue name routes :queue — both link
    # kinds ride the SAME hook paths, so this leg proves the link-kind
    # namespace resolution end to end.
    {client, csock} = start_connection()
    begin_session(client, 1)
    cbs_put_token(client, @q_eh)
    attach_receiver(client, 1, 0, "chaos-eh-q-rx", @q_eh)

    attach_receiver(
      client,
      1,
      1,
      "chaos-eh-partition-rx",
      "/eventhubs/#{@eh_hub}/ConsumerGroups/$Default/Partitions/0"
    )

    flow_credit(client, 1, 0, 5)
    flow_credit(client, 1, 1, 5)

    # The QUEUE link (namespace :sb, flag OFF) delivers normally...
    assert {:ok, _} =
             eventually(
               fn ->
                 if queue_transfer?(client, 1, 0), do: {:ok, :queue_delivered}
               end,
               timeout_ms: 5_000
             )

    # ... while the EH link (namespace :eh, flag ON) is starved: no transfer.
    assert {:timeout, _} =
             eventually(
               fn ->
                 if eh_transfer?(client, 1, 1), do: {:ok, :eh_delivered_while_starved}
               end,
               timeout_ms: 3_000
             )

    events = drain_chaos_telemetry()

    assert Enum.any?(events, fn {ev, _m, md} ->
             ev == :credit_starved and md.namespace == :eh and md.handle == 1
           end)

    # Flag clears: the EH link recovers on the next flow.
    Application.put_env(:smalt, :eh_chaos_starve_credits, nil)
    flow_credit(client, 1, 1, 5)

    assert {:ok, _} =
             eventually(
               fn ->
                 if eh_transfer?(client, 1, 1), do: {:ok, :eh_delivered}
               end,
               timeout_ms: 5_000
             )

    :telemetry.detach(tid)
    stop(client, csock)
  end

  # ===========================================================================
  # Anti-vacuity: flags off = zero interference
  # ===========================================================================

  test "non-vacuity witness: all flags off means normal delivery, no chaos frames, no chaos telemetry" do
    tid = attach_chaos_telemetry()
    {:ok, _} = QueueStore.ensure_queue(@q_off)
    {:ok, _} = QueueStore.enqueue(@q_off, "chaos-off-payload", message_id: "chaos-off-m1")

    {client, csock} = start_connection()
    begin_session(client, 1)
    cbs_put_token(client, @q_off)
    attach_receiver(client, 1, 0, "chaos-off-rx", @q_off)
    flow_credit(client, 1, 0, 5)

    # The delivery lands normally.
    assert {:ok, t} =
             eventually(
               fn ->
                 case first_transfer(client, 1) do
                   nil -> :no_delivery
                   t -> {:ok, t}
                 end
               end,
               timeout_ms: 5_000
             )

    # Structural sync: settle the delivery (closes the re-avail channel), so
    # the absence window below can only be explained by the flags being off.
    settle(client, 1, t.perf[:delivery_id])

    assert {:timeout, _} =
             eventually(
               fn ->
                 cond do
                   Enum.any?(frames(client, 1), &(&1.kind in [:detach, :end])) ->
                     {:ok, :chaos_frame_on_wire}

                   drain_chaos_telemetry() != [] ->
                     {:ok, :chaos_telemetry_fired}

                   true ->
                     :clean
                 end
               end,
               timeout_ms: 3_000
             )

    :telemetry.detach(tid)
    stop(client, csock)
  end

  # ===========================================================================
  # Telemetry capture
  # ===========================================================================

  defp attach_chaos_telemetry do
    test_pid = self()
    id = "chaos-court-#{:erlang.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        id,
        [
          [:smalt, :chaos, :link_detach],
          [:smalt, :chaos, :credit_starved],
          [:smalt, :chaos, :session_timeout]
        ],
        fn [:smalt, :chaos, ev], measurements, metadata, _ ->
          send(test_pid, {:chaos_telemetry, ev, measurements, metadata})
        end,
        nil
      )

    id
  end

  defp drain_chaos_telemetry(acc \\ []) do
    receive do
      {:chaos_telemetry, ev, m, md} -> drain_chaos_telemetry([{ev, m, md} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ===========================================================================
  # Wire harness (kd134 pattern): real TCP socket, real Connection GenServer,
  # codec-native frames, real CBS put-token.
  # ===========================================================================

  defp frame(ch, {name, fields}), do: FrameCodec.encode_frame(:amqp, ch, {name, fields})

  defp start_connection(opts \\ []) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    {:ok, csock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    {:ok, ssock} = :gen_tcp.accept(lsock)
    {:ok, conn} = Smalt.Amqp.Connection.start_link(Keyword.put(opts, :socket, ssock))
    :ok = :gen_tcp.controlling_process(ssock, conn)

    client = start_client(csock)

    :ok = csend(client, "AMQP\x00\x01\x00\x00")

    :ok =
      csend(client, frame(0, {:open, %{container_id: "chaos-client", max_frame_size: 65_536}}))

    {client, csock}
  end

  defp begin_session(client, ch) do
    :ok =
      csend(
        client,
        frame(ch, {:begin, %{next_outgoing_id: 0, incoming_window: 10_000, outgoing_window: 10_000}})
      )
  end

  defp attach_receiver(client, ch, handle, name, address) do
    :ok =
      csend(
        client,
        frame(ch, {:attach, %{name: name, handle: handle, role: true, source: %{address: address}}})
      )
  end

  defp flow_credit(client, ch, handle, credit) do
    :ok = csend(client, frame(ch, {:flow, %{handle: handle, link_credit: credit, delivery_count: 0}}))
  end

  defp settle(client, ch, delivery_id) do
    :ok =
      csend(
        client,
        frame(ch, {
          :disposition,
          %{role: true, first: delivery_id, last: delivery_id, settled: true, state: :accepted}
        })
      )
  end

  # Real CBS put-token over the wire for the queue audience (the queue attach
  # is CBS-gated while a claim cache lives).
  defp cbs_put_token(client, queue) do
    :ok =
      csend(client, frame(3, {:attach, %{name: "cbs", handle: 0, role: false, target: %{address: "$cbs"}}}))

    sr = Smalt.Amqp.SasVerifier.endpoint() <> "/" <> queue
    se = System.system_time(:second) + 3_600
    key = Smalt.Amqp.SasVerifier.shared_key()
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}"))

    token = "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

    sections = [
      {:properties, %{message_id: "chaos-pt"}},
      {:application_properties,
       %{
         "operation" => "put-token",
         "type" => "servicebus.windows.net:sastoken",
         "name" => queue
       }},
      {:body_amqp_value, token}
    ]

    :ok =
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

  # --- wire client -----------------------------------------------------------

  defp start_client(sock) do
    name = String.to_atom("chaos_client_#{:erlang.unique_integer([:positive])}")
    {:ok, pid} = Task.start(fn -> client_loop(sock, %{}, <<>>) end)
    Process.register(pid, name)
    name
  end

  # Ordered, fire-and-forget send through the client process (the only
  # holder of the client TCP socket). client_loop's {:send, _} branch
  # performs the real :gen_tcp.send; sequencing across calls is the
  # client's mailbox order.
  defp csend(client, iodata) do
    send(client, {:send, iodata})
    :ok
  end

  # Passive recv in 50ms observation slices (POLL-STEP, the broker pump's own
  # shape) — never a coordination sleep.
  defp client_loop(sock, rx, buf) do
    receive do
      {:send, frame} ->
        :ok = :gen_tcp.send(sock, frame)
        client_loop(sock, rx, buf)

      {:snapshot, from, ch} ->
        send(from, {:chaos_snapshot, Enum.reverse(Map.get(rx, ch, []))})
        client_loop(sock, rx, buf)

      {:stop, _reply} ->
        :ok
    after
      0 ->
        case :gen_tcp.recv(sock, 0, 50) do
          {:ok, data} ->
            buf2 = <<buf::binary, data::binary>>
            buf3 = peel_header(buf2)
            {rx2, buf4} = absorb(buf3, rx)
            client_loop(sock, rx2, buf4)

          {:error, :timeout} ->
            client_loop(sock, rx, buf)

          {:error, _closed} ->
            :ok
        end
    end
  end

  defp peel_header(<<"AMQP", 0, 1, 0, 0, tail::binary>>), do: tail
  defp peel_header(buf), do: buf

  defp absorb(buf, rx) when byte_size(buf) < 8, do: {rx, buf}

  defp absorb(buf, rx) do
    <<size::unsigned-integer-size(32), _rest::binary>> = buf

    if byte_size(buf) >= size do
      <<frame_bytes::binary-size(^size), tail::binary>> = buf

      case FrameCodec.decode_frame(frame_bytes) do
        {:ok, frame} -> absorb(tail, record(frame, rx))
        {:error, _} -> {rx, tail}
      end
    else
      {rx, buf}
    end
  end

  defp record(%{channel: ch, performative: %{performative: kind}} = frame, rx) do
    mid =
      if kind == :transfer and is_binary(frame[:payload]) do
        case FrameCodec.decode_message(frame[:payload]) do
          {:ok, sections} ->
            Enum.find_value(sections, fn
              {:properties, p} when is_map(p) -> p[:message_id]
              _ -> nil
            end)

          _ ->
            nil
        end
      end

    entry = %{kind: kind, perf: frame.performative, payload: frame[:payload], mid: mid}
    Map.update(rx, ch, [entry], &[entry | &1])
  end

  defp record(_frame, rx), do: rx

  # --- observation helpers ---------------------------------------------------

  defp frames(client, ch) do
    send(client, {:snapshot, self(), ch})

    receive do
      {:chaos_snapshot, list} -> list
    after
      2_000 -> flunk("chaos client did not answer snapshot")
    end
  end

  defp transfer_count(client, ch), do: Enum.count(frames(client, ch), &(&1.kind == :transfer))

  defp first_transfer(client, ch), do: Enum.find(frames(client, ch), &(&1.kind == :transfer))

  # Transfers on a handle, mid-tolerant: the queue legs decode message-ids
  # (leftover rows from earlier runs are tolerated), the EH legs count any
  # transfer on the EH handle.
  defp queue_transfer?(client, ch, handle) do
    frames(client, ch)
    |> Enum.any?(&(&1.kind == :transfer and &1.perf[:handle] == handle and is_binary(&1.mid)))
  end

  defp eh_transfer?(client, ch, handle) do
    frames(client, ch) |> Enum.any?(&(&1.kind == :transfer and &1.perf[:handle] == handle))
  end

  defp detach_texts(client, ch) do
    for %{kind: :detach} = f <- frames(client, ch), t <- error_texts(f.perf[:error]), do: t
  end

  defp end_error_texts(client, ch) do
    for %{kind: :end} = f <- frames(client, ch), t <- error_texts(f.perf[:error]), do: t
  end

  # Tolerant error digger: the codec hands the client the error either as a
  # described(0x1D) [condition, description, info] list or a normalized map.
  defp error_texts(nil), do: []

  defp error_texts({:described, _desc, fields}) when is_list(fields) do
    for f <- fields, t = text_of(f), do: t
  end

  defp error_texts(%{} = e), do: for(f <- [e[:condition], e[:description]], t = text_of(f), do: t)
  defp error_texts(_), do: []

  defp text_of({:symbol, s}) when is_binary(s), do: s
  defp text_of(s) when is_binary(s), do: s
  defp text_of(_), do: nil

  defp stop(client, csock) do
    :gen_tcp.close(csock)

    if pid = Process.whereis(client) do
      send(pid, {:stop, self()})
    end
  end

  defp cleanup_queue_rows(queue) do
    if :ets.info(:smalt_sb_messages) != :undefined do
      for {k, _} <- :ets.tab2list(:smalt_sb_messages),
          is_tuple(k) and is_binary(elem(k, 0)) and String.contains?(elem(k, 0), queue) do
        :ets.delete(:smalt_sb_messages, k)
      end
    end
  end
end
