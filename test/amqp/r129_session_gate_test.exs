defmodule Smalt.Amqp.R129SessionGateTest do
  @moduledoc """
  Repair lane R129 regression court (exploits from adversarial lane W5-17):
  two session-gate bypasses in `Smalt.Amqp.Connection`.

  1. Trailing-slash shadow queue: "amqps://h:5671/q/" previously kept the FULL
     URI as the store key (the `entity != ""` guard let "q/" fall through), a
     distinct namespace that bypassed the requiresSession gate.
  2. Unfiltered receiver on a requiresSession queue: the attach case consulted
     sessions only for links WITH a session filter; a receiver without
     com.microsoft:session-filter registered with session_id: nil and
     claim_candidates' nil filter matched ALL messages (cross-session drain).

  Runs over the real socket harness (same shape as ConnectionTest): raw
  :gen_tcp client, real FrameCodec, real QueueStore — Chicago discipline.
  """

  use ExUnit.Case, async: false

  alias Smalt.Amqp.{Connection, FrameCodec}

  @header "AMQP\x00\x01\x00\x00"
  @sasl_header "AMQP\x03\x01\x00\x00"
  @test_key "test-shared-key-0123456789abcdef012345"

  setup do
    Application.put_env(:smalt, :sb_shared_key, @test_key)

    SmaltTest.Lifecycle.ensure_store_up()

    for table <- [:smalt_sb_queues, :smalt_sb_messages, :smalt_sb_locks, :smalt_sb_tokens] do
      if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    end

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
        {:ok, pid} = Connection.start_link(socket: sock)
        :ok = :gen_tcp.controlling_process(sock, pid)
        {:ok, pid}
      end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
    {:ok, conn} = Task.await(accept_task, 5000)

    queue = "r129q-#{System.unique_integer([:positive])}"

    # requiresSession = true via the ARM resource record the store reads
    # (queue_settings -> arm_queue_properties matches key suffix "/queues/<name>")
    :ets.insert(:smalt_resources, {
      "namespaces/r129/queues/#{queue}",
      %{"properties" => %{"requiresSession" => true}}
    })

    on_exit(fn ->
      # Row has no "id"; without cleanup it poisons later semantic-read
      # tests with "vacuous identity" refusals.
      if :ets.info(:smalt_resources) != :undefined do
        :ets.delete_all_objects(:smalt_resources)
      end

      Application.delete_env(:smalt, :sb_shared_key)
    end)

    if GenServer.whereis(Smalt.Amqp.CbsRouter) do
      GenServer.stop(Smalt.Amqp.CbsRouter)
    end

    {:ok, _} = GenServer.start(Smalt.Amqp.CbsRouter, [], name: Smalt.Amqp.CbsRouter)

    # mint claims for every audience spelling the exploit paths touch
    mint_claims(conn, queue)

    %{client: client, conn: conn, queue: queue}
  end

  defp mint_claims(conn, queue) do
    Enum.each(
      [
        "sb://127.0.0.1:5672/#{queue}",
        "sb://127.0.0.1:5672/#{queue}/"
      ],
      fn audience ->
        sr = audience
        se = System.system_time(:second) + 600

        sig =
          Base.encode64(
            :crypto.mac(:hmac, :sha256, @test_key, sr <> "\n" <> Integer.to_string(se))
          )

        token =
          "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

        request = %{
          operation: "put-token",
          type: "servicebus.windows.net:sastoken",
          name: sr,
          expiration: se,
          token: token
        }

        assert {:ok, {200, _}} =
                 Smalt.Amqp.CbsRouter.put_token(Smalt.Amqp.CbsRouter, request, conn)
      end
    )
  end

  # --- exploit 1: trailing-slash shadow queue --------------------------------

  test "enqueue via '<q>/' without session is refused; WITH session lands on '<q>'", ctx do
    client = ctx.client
    queue = ctx.queue
    :ok = handshake(client)

    # sender link with a trailing-slash target — previously a shadow namespace
    :ok =
      send_bytes(
        client,
        enc_frame(
          :amqp,
          0,
          {:attach, %{name: "s1", handle: 0, role: false, target: %{address: queue <> "/"}}}
        )
      )

    assert %{performative: %{performative: :attach}} = recv_frame(client)

    # no group-id -> enqueue now errors :session_required (was {:ok, 1} into
    # the shadow queue)
    :ok =
      send_bytes(
        client,
        enc_frame(
          :amqp,
          0,
          {:transfer,
           %{
             handle: 0,
             delivery_id: 7,
             delivery_tag: <<1, 2, 3, 4>>,
             message_format: 0,
             settled: true,
             more: false
           }, {:sections, [{:body_amqp_value, "m1"}]}}
        )
      )

    resp = recv_frame(client)

    assert resp.performative.performative == :close,
           "expected error close, got: #{inspect(resp.performative.performative)}"

    # nothing may land in the shadow namespace
    Process.sleep(50)
    assert 0 == count_state(queue <> "/", :any)
    assert 0 == count_state(queue, :any)

    # positive control: WITH a group-id the enqueue succeeds — and the
    # message must be keyed under the BARE entity (namespace collapse)
    {:ok, listener2} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port2} = :inet.port(listener2)

    accept2 =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listener2, 5000)
        {:ok, pid} = Connection.start_link(socket: sock)
        :ok = :gen_tcp.controlling_process(sock, pid)
        {:ok, pid}
      end)

    {:ok, client2} = :gen_tcp.connect(~c"127.0.0.1", port2, [:binary, active: false], 5000)
    {:ok, conn2} = Task.await(accept2, 5000)

    # CBS claims are per-connection; mint for the second connection too
    mint_claims(conn2, queue)

    :ok = handshake(client2)

    :ok =
      send_bytes(
        client2,
        enc_frame(
          :amqp,
          0,
          {:attach, %{name: "s2", handle: 0, role: false, target: %{address: queue <> "/"}}}
        )
      )

    assert %{performative: %{performative: :attach}} = recv_frame(client2)

    :ok =
      send_bytes(
        client2,
        enc_frame(
          :amqp,
          0,
          {:transfer,
           %{
             handle: 0,
             delivery_id: 8,
             delivery_tag: <<2, 2, 3, 4>>,
             message_format: 0,
             settled: true,
             more: false
           }, {:sections, [{:properties, %{group_id: "sid-A"}}, {:body_amqp_value, "m2"}]}}
        )
      )

    assert %{performative: %{performative: :disposition, state: :accepted}} = recv_frame(client2)

    assert 1 == count_state(queue, :any), "message must land under the bare entity"
    assert 0 == count_state(queue <> "/", :any)

    # a sessioned receiver on the BARE name can claim it
    :ok =
      send_bytes(
        client2,
        enc_frame(
          :amqp,
          0,
          {:attach,
           %{
             name: "r2",
             handle: 1,
             role: true,
             source: %{
               address: queue,
               filter: {:map_rhea, %{{:symbol, "com.microsoft:session-filter"} => "sid-A"}}
             }
           }}
        )
      )

    at = recv_until(client2, :attach)
    assert at.performative.role == false
    assert is_integer(at.performative.properties["com.microsoft:locked-until-utc"])
  end

  # --- exploit 2: unfiltered receiver on a requiresSession queue -------------

  test "unfiltered receiver attach on sessionful queue -> typed detach; sessioned still works",
       ctx do
    client = ctx.client
    queue = ctx.queue
    sid = "s-" <> Integer.to_string(System.unique_integer([:positive]))

    # seed a session message so a working sessioned receiver has something
    assert {:ok, _} = Smalt.Amqp.QueueStore.enqueue(queue, "m", session_id: sid)

    :ok = handshake(client)

    # unfiltered receiver (no session-filter): must be refused, not registered
    :ok =
      send_bytes(
        client,
        enc_frame(
          :amqp,
          0,
          {:attach, %{name: "r-none", handle: 0, role: true, source: %{address: queue}}}
        )
      )

    echo = recv_frame(client)
    assert echo.performative.performative == :attach

    det = recv_frame(client)
    assert det.performative.performative == :detach
    assert det.performative.handle == 0
    assert det.performative.closed == true
    assert error_condition(det.performative.error) == "com.microsoft:session-cannot-be-locked"

    # the link must NOT be registered: a client cleanup detach for handle 0
    # must not match a registered link (a queue+session link release would
    # kill a legitimate receiver's session lock)
    :ok = send_bytes(client, enc_frame(:amqp, 0, {:detach, %{handle: 0, closed: true}}))
    Process.sleep(50)

    # lock must still be free: a sessioned receiver on the same sid attaches
    # and gets the lock grant right after
    :ok =
      send_bytes(
        client,
        enc_frame(
          :amqp,
          0,
          {:attach,
           %{
             name: "r1",
             handle: 1,
             role: true,
             source: %{
               address: queue,
               filter: {:map_rhea, %{{:symbol, "com.microsoft:session-filter"} => sid}}
             }
           }}
        )
      )

    at = recv_until(client, :attach)
    assert at.performative.role == false
    assert is_integer(at.performative.properties["com.microsoft:locked-until-utc"])
  end

  # --- harness helpers ---------------------------------------------------------

  defp enc_frame(layer, channel, performative),
    do: FrameCodec.encode_frame(layer, channel, performative)

  defp send_bytes(client, iodata), do: :gen_tcp.send(client, iodata)

  defp recv_until(client, name, timeout \\ 2000)

  defp recv_until(client, name, timeout) do
    frame = recv_frame(client, timeout)

    if frame.performative.performative == name,
      do: frame,
      else: recv_until(client, name, timeout)
  end

  defp recv_frame(client, timeout \\ 2000) do
    frame = do_recv_frame(client, timeout)

    if frame.performative.performative == :flow do
      recv_frame(client, timeout)
    else
      frame
    end
  end

  defp do_recv_frame(client, timeout) do
    {:ok, hdr} = recv_exact(client, 8, timeout)
    <<size::unsigned-integer-size(32), _doff, _type, _channel::16>> = hdr
    {:ok, body} = recv_exact(client, size - 8, timeout)

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

  defp error_condition(%{condition: c}) when is_binary(c), do: c
  defp error_condition([{:symbol, c} | _]) when is_binary(c), do: c

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
        enc_frame(
          :amqp,
          0,
          {:open, %{container_id: "r129-client", max_frame_size: 65_536, channel_max: 65_535}}
        )
      )

    recv_frame(client)

    :ok =
      send_bytes(
        client,
        enc_frame(
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

    recv_frame(client)
    :ok
  end
end
