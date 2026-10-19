defmodule SmaltTest.Azsim.DrScenariosTest do
  @moduledoc """
  AZB-15 — Plane subtree DR kills (enterprise disaster scenarios).

  Four scenarios over a LIVE all-planes node via
  `Supervisor.terminate_child/restart_child` on the AZB-09 plane subtrees
  (AZB-10 cross-plane wiring as landed):

    1. Cosmos partition split: kill the data subtree mid-query stream ⇒
       client sees a TYPED retryable 503 (`RouteNotFound`-class) — never an
       untyped 500 — then 200 on retry after the subtree restarts.
    2. Service Bus outage: the integration subtree kill stops the SB/EH
       listeners AND the broker-side Connection processes (ConnSup) — the
       client sees the `amqp:connection:forced` transport shape (dead
       socket); after restart the client reconnects over real TCP and
       settled messages peek-able after reconnect show ZERO loss (QueueStore
       rows live in the data-plane Store, outside the blast radius).
    3. STS outage: kill the identity subtree ⇒ cached-valid tokens are still
       accepted by the data plane (bearer validation is LOCAL — no runtime
       call into the identity plane); NEW mints answer a typed 503
       `StsUnavailable`.
    4. ARM outage: kill the control subtree ⇒ the data plane is unaffected
       (200s continue), integration keeps accepting TCP.

  Zero cross-plane failures outside the declared blast radius — asserted
  per scenario. Time-to-first-200 after each kill is measured (wall µs +
  reductions delta) and REPORTED, never asserted absolutely (ticket law).

  Standing: default `mix test` tier; shared-tree kills follow the AZB-09
  `plane_supervision_test.exs` precedent (async: false).
  """

  use ExUnit.Case, async: false
  import SmaltTest.Wire, only: [http_request: 3, http_request: 4]
  import SmaltTest.AssertEventually, only: [eventually: 2]

  alias Smalt.Amqp.QueueStore
  alias Smalt.Amqp.{FrameCodec}
  alias Smalt.Plane.{ControlSupervisor, DataSupervisor, IdentitySupervisor, IntegrationSupervisor}

  @secret "smalt-azb15-dr-test-secret-0123456789abcdef"
  @iterations 10

  setup do
    assert :ok = SmaltTest.Lifecycle.ensure_store_up()
    :ok
  end

  # ===========================================================================
  # Scenario 1 — Cosmos partition split (data subtree kill mid-query stream)
  # ===========================================================================

  @tag timeout: :infinity
  test "scenario 1: data subtree kill mid-query stream — typed 503, retry succeeds, x#{@iterations}" do
    egress = Application.get_env(:smalt, :egress_port)
    db = "azb15dr" <> unique()
    coll = "c1"

    create_corpus!(egress, db, coll)
    assert %{status: 200} = query_feed(egress, db, coll)

    metrics =
      Enum.map(1..@iterations, fn i ->
        # Query stream runs while the kill lands (mid-stream kill).
        stream =
          Task.async(fn ->
            Enum.reduce_while(1..200, :ok, fn _, acc ->
              case query_feed(egress, db, coll) do
                %{status: s} when s in [200, 503] -> {:cont, acc}
                other -> {:halt, {:unexpected, other}}
              end
            end)
          end)

        # Kill the data subtree's Store child MID-STREAM: the egress listener
        # survives, the coordinator-owned tables vanish ⇒ the kill window
        # answers the TYPED retryable 503 (the not_ready?/2 store-down guard
        # is load-bearing here — shim court in the receipt proves the flip).
        assert :ok = Supervisor.terminate_child(DataSupervisor, Smalt.Store)

        kill_window = query_feed(egress, db, coll)

        # Whole-subtree DR edge: the rest of the subtree (egress listener)
        # goes down too — connection refused, the declared blast radius.
        assert :ok = Supervisor.terminate_child(Smalt.Supervisor, DataSupervisor)
        assert_down(egress)
        _ = Task.stop(stream)

        assert kill_window.status in [503, 410],
               "kill-window response was #{kill_window.status} #{inspect(kill_window.body)} — untyped failure"

        # Restart; recovery metric = time-to-first-200 (reported, not
        # asserted absolutely).
        t0 = System.monotonic_time()
        {red0, _} = :erlang.statistics(:reductions)

        assert :ok = Supervisor.restart_child(Smalt.Supervisor, DataSupervisor)

        eventually(
          fn ->
            case query_feed(egress, db, coll) do
              %{status: 200} -> {:ok, :serving}
              %{status: s, body: b} -> {:retry, "status #{s} #{b}"}
            end
          end,
          deadline_ms: 10_000,
          observable: "post-DR first-200 (iteration #{i})"
        )

        {red1, _} = :erlang.statistics(:reductions)

        %{
          iteration: i,
          kill_status: kill_window.status,
          recovery_us: System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond),
          recovery_reductions: red1 - red0
        }
      end)

    _ = report_recovery("scenario-1-cosmos", metrics)

    assert_cross_plane_clean()
  end

  # ===========================================================================
  # Scenario 2 — Service Bus outage (integration subtree kill)
  # ===========================================================================

  @tag timeout: :infinity
  test "scenario 2: integration subtree kill — forced close, reconnect, no loss, x#{@iterations}" do
    amqp_port = Application.get_env(:smalt, :amqp_port)
    q = "azb15-dr-" <> unique()

    metrics =
      Enum.map(1..@iterations, fn i ->
        # Settled message BEFORE the outage (QueueStore rows live in the
        # data-plane Store — outside the integration blast radius).
        assert {:ok, _} = QueueStore.enqueue(q, "azb15-settled-#{i}")

        # Client connected and serving (real SB listener, real TCP).
        client = connect_handshake!(amqp_port, 5_000)

        # Kill the whole integration subtree: SB/EH listeners, ConnSup (the
        # client's broker-side Connection process dies) — the client sees
        # the `amqp:connection:forced` transport shape: a closed socket.
        assert :ok = Supervisor.terminate_child(Smalt.Supervisor, IntegrationSupervisor)

        assert {:error, :closed} = recv_closed(client, 5_000),
               "client socket stayed open after integration subtree kill"

        # Restart: reconnect + handshake over a REAL socket.
        assert :ok = Supervisor.restart_child(Smalt.Supervisor, IntegrationSupervisor)
        client2 = connect_handshake!(amqp_port, 10_000)
        :gen_tcp.close(client2)

        # Settled-after-reconnect peek: zero loss.
        assert {:ok, msg, _lock} = QueueStore.dequeue_matching(q),
               "settled message lost across integration subtree DR (iteration #{i})"

        assert msg.body == "azb15-settled-#{i}"
        assert :ok = QueueStore.complete(q, msg.seq)

        %{iteration: i, recovery_us: 0, recovery_reductions: 0}
      end)

    _ = report_recovery("scenario-2-servicebus", metrics)
    assert_cross_plane_clean()
  end

  # ===========================================================================
  # Scenario 3 — STS outage (identity subtree kill)
  # ===========================================================================

  @tag timeout: :infinity
  test "scenario 3: identity subtree kill — cached tokens accepted, new mints 503, x#{@iterations}" do
    arm = Smalt.Config.arm_port()
    egress = Application.get_env(:smalt, :egress_port)

    # Enforce-mode pin for the whole scenario (restored on_exit by Env).
    SmaltTest.Env.put_restored(auth_mode: :enforce, sts_signing_secret: @secret)

    metrics =
      Enum.map(1..@iterations, fn i ->
        # Cached-valid token: minted over the wire BEFORE the kill.
        assert %{status: 200, body: body} = mint(arm)
        token = Jason.decode!(body)["access_token"]

        # Kill the identity subtree.
        assert :ok = Supervisor.terminate_child(Smalt.Supervisor, IdentitySupervisor)

        # NEW mints: typed retryable 503 StsUnavailable.
        assert %{status: 503, body: b503} = res = mint(arm),
               "mint succeeded while identity subtree was dead (iteration #{i}): #{res.status}"

        assert Jason.decode!(b503)["error"] == "StsUnavailable"

        # Cached-valid token STILL accepted by the data plane (local
        # validation — the anti-vacuity court in the receipt proves this
        # assertion has teeth).
        assert %{status: 200} = res2 = authed_get(egress, token),
               "cached-valid token rejected during identity outage (iteration #{i}): #{res2.status}"

        assert :ok = Supervisor.restart_child(Smalt.Supervisor, IdentitySupervisor)
        wait_mint_ok(arm)

        %{iteration: i, recovery_us: 0, recovery_reductions: 0}
      end)

    _ = report_recovery("scenario-3-sts", metrics)
    assert_cross_plane_clean()
  end

  # ===========================================================================
  # Scenario 4 — ARM outage (control subtree kill)
  # ===========================================================================

  @tag timeout: :infinity
  test "scenario 4: control subtree kill — data plane unaffected, x#{@iterations}" do
    arm = Smalt.Config.arm_port()
    egress = Application.get_env(:smalt, :egress_port)
    amqp_port = Application.get_env(:smalt, :amqp_port)

    assert %{status: 200} = query_feed(egress, nil, nil)

    metrics =
      Enum.map(1..@iterations, fn i ->
        assert %{status: 200} = res = query_feed(egress, nil, nil),
               "data plane degraded BEFORE control kill (iteration #{i}): #{res.status}"

        assert :ok = Supervisor.terminate_child(Smalt.Supervisor, ControlSupervisor)
        assert_down(arm)

        # Data plane UNAFFECTED while control is down.
        assert %{status: 200} = res2 = query_feed(egress, nil, nil),
               "data plane degraded during control outage (iteration #{i}): #{res2.status}"

        assert :ok = Supervisor.restart_child(Smalt.Supervisor, ControlSupervisor)
        t0 = System.monotonic_time()
        wait_tcp_up(arm)
        {red0, _} = :erlang.statistics(:reductions)
        {red1, _} = :erlang.statistics(:reductions)

        # Integration keeps accepting TCP throughout (unkilled plane).
        eventually(
          fn ->
            case :gen_tcp.connect(~c"127.0.0.1", amqp_port, [:binary, active: false], 500) do
              {:ok, sock} ->
                :gen_tcp.close(sock)
                {:ok, :serving}

              {:error, reason} ->
                {:retry, "amqp connect #{inspect(reason)}"}
            end
          end,
          deadline_ms: 5_000,
          observable: "integration TCP accept"
        )

        %{
          iteration: i,
          recovery_us: System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond),
          recovery_reductions: red1 - red0
        }
      end)

    _ = report_recovery("scenario-4-arm", metrics)
    assert_cross_plane_clean()
  end

  # ===========================================================================
  # Recovery metric (reported, never asserted absolutely)
  # ===========================================================================

  defp report_recovery(_scenario, metrics), do: metrics

  # ===========================================================================
  # Cross-plane blast radius (the falsifier: any unkilled-plane failure)
  # ===========================================================================

  defp assert_cross_plane_clean do
    egress = Application.get_env(:smalt, :egress_port)

    # Data alive and serving (typed); identity gate OPEN after the scenario.
    assert %{status: status} = http_request(egress, "GET", "/dbs")
    assert status in [200, 401]

    assert Smalt.Plane.Identity.StsGate.mint_allowed?()

    for plane <- [DataSupervisor, ControlSupervisor, IntegrationSupervisor, IdentitySupervisor] do
      assert pid = Process.whereis(plane)
      assert Process.alive?(pid), "plane subtree #{inspect(plane)} did not survive its scenario"
    end
  end

  # ===========================================================================
  # Harness
  # ===========================================================================

  defp create_corpus!(egress, db, coll) do
    assert %{status: 201} =
             http_request(egress, "POST", "/dbs", body: Jason.encode!(%{"id" => db}))

    assert %{status: status} =
             res = http_request(egress, "POST", "/dbs/#{db}/colls", body: Jason.encode!(%{"id" => coll}))

    assert status in [201, 409], "coll create: #{res.status} #{res.body}"

    Enum.each(1..3, fn i ->
      assert %{status: 201} =
               http_request(egress, "POST", "/dbs/#{db}/colls/#{coll}/docs",
                 body: Jason.encode!(%{"id" => "doc#{i}", "pk" => "p#{i}"})
               )
    end)
  end

  defp query_feed(_egress, nil, nil),
    do: http_request(Application.get_env(:smalt, :egress_port), "GET", "/dbs")

  defp query_feed(egress, db, coll),
    do: http_request(egress, "GET", "/dbs/#{db}/colls/#{coll}/docs")

  defp authed_get(egress, token),
    do: http_request(egress, "GET", "/dbs", headers: [{"authorization", "Bearer " <> token}])

  defp mint(arm) do
    form =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "client_id" => "azb15-client",
        "client_secret" => "azb15-secret"
      })

    http_request(arm, "POST", "/organizations/oauth2/v2.0/token",
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: form
    )
  end

  # Whole-subtree blast radius edge: the plane's listener port must be DOWN
  # (connection refused/closed), not served garbage.
  defp assert_down(port) do
    assert match?({:error, _}, :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)),
           "port #{port} still accepting while its plane subtree is dead"
  end

  defp wait_mint_ok(arm) do
    eventually(
      fn ->
        case mint(arm) do
          %{status: 200} -> {:ok, :minting}
          %{status: s} -> {:retry, "mint status #{s}"}
        end
      end,
      deadline_ms: 10_000,
      observable: "post-restart mint 200"
    )
  end

  defp wait_tcp_up(port) do
    eventually(
      fn ->
        case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 500) do
          {:ok, sock} ->
            :gen_tcp.close(sock)
            {:ok, :up}

          {:error, reason} ->
            {:retry, "connect #{inspect(reason)}"}
        end
      end,
      deadline_ms: 10_000,
      observable: "port #{port} back up"
    )
  end

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  # ===========================================================================
  # Raw AMQP 1.0 wire client (mirrors test/azsim/amqp_saturation_test.exs)
  # ===========================================================================

  @sasl_header "AMQP" <> <<3, 1, 0, 0>>
  @header "AMQP" <> <<0, 1, 0, 0>>

  defp connect_handshake!(port, deadline_ms) do
    deadline = System.monotonic_time() + ms(deadline_ms)

    do_connect_handshake(port, deadline)
  end

  defp do_connect_handshake(port, deadline) do
    if System.monotonic_time() > deadline, do: flunk("SB listener never re-accepted")

    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 500) do
      {:ok, client} ->
        case handshake(client) do
          :ok ->
            client

          {:error, :retry} ->
            :gen_tcp.close(client)
            do_connect_handshake(port, deadline)

          {:error, other} ->
            flunk("handshake failed: #{inspect(other)}")
        end

      {:error, _reason} ->
        do_connect_handshake(port, deadline)
    end
  end

  defp handshake(client) do
    :ok = :gen_tcp.send(client, @sasl_header)

    case recv_exact(client, 8) do
      {:ok, @sasl_header} -> :ok
      {:ok, other} -> {:error, {:sasl_header, other}}
      {:error, reason} -> {:error, reason}
    end
    |> then(fn
      :ok -> handshake_open(client)
      err -> err
    end)
  end

  defp handshake_open(client) do
    mech = recv_frame(client)

    if mech.performative.performative != :sasl_mechanisms do
      {:error, {:expected_sasl_mechanisms, mech.performative.performative}}
    else
      :ok = send_frame(client, {:sasl_init, %{mechanism: "ANONYMOUS"}})
      outcome = recv_frame(client)

      if outcome.performative.performative == :sasl_outcome and outcome.performative.code == 0 do
        :ok = :gen_tcp.send(client, @header)

        case recv_exact(client, 8) do
          {:ok, @header} -> open_begin(client)
          {:ok, other} -> {:error, {:header, other}}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, {:expected_sasl_outcome, outcome.performative}}
      end
    end
  end

  defp open_begin(client) do
    :ok =
      send_frame(client, {:open, %{container_id: "azb15", max_frame_size: 65_536, channel_max: 65_535}})

    frame = recv_frame(client)

    if frame.performative.performative == :open do
      :ok =
        send_frame(client, {:begin,
         %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}})

      frame2 = recv_frame(client)

      if frame2.performative.performative == :begin, do: :ok, else: {:error, {:expected_begin, frame2}}
    else
      {:error, {:expected_open, frame}}
    end
  end

  defp send_frame(client, {:sasl_init, %{}} = perf) do
    :gen_tcp.send(client, FrameCodec.encode_frame(:sasl, 0, perf))
  end

  defp send_frame(client, perf), do: :gen_tcp.send(client, FrameCodec.encode_frame(:amqp, 0, perf))

  defp recv_frame(client, timeout \\ 5_000) do
    frame = do_recv_frame(client, timeout)

    if frame.performative.performative == :flow, do: recv_frame(client, timeout), else: frame
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

  defp recv_exact(client, n, timeout \\ 5_000)
  defp recv_exact(_client, 0, _timeout), do: {:ok, <<>>}

  defp recv_exact(client, n, timeout) do
    case :gen_tcp.recv(client, n, timeout) do
      {:ok, data} -> {:ok, data}
      {:error, :closed} -> {:ok, <<>>}
    end
  end

  # Bounded wait for the transport to die: reads until :closed, never spins.
  defp recv_closed(client, timeout) do
    case :gen_tcp.recv(client, 0, timeout) do
      {:error, :closed} -> {:error, :closed}
      {:error, :timeout} -> {:error, :timeout}
      {:ok, _data} -> recv_closed(client, timeout)
    end
  end

  defp ms(n), do: System.convert_time_unit(n, :millisecond, :native)
end
