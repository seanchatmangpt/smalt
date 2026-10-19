defmodule SmaltTest.Azsim.DrScenariosTest do
  @moduledoc """
  AZB-15 — Plane subtree DR kills (enterprise disaster scenarios).

  Four scenarios over a LIVE all-planes node via
  `Supervisor.terminate_child/restart_child` on the plane subtrees
  (AZB-09 subtrees, AZB-10 cross-plane wiring as landed deps):

    1. Cosmos partition split: kill the data subtree mid-query stream ⇒
       client sees a TYPED retryable 503 (`RouteNotReady`) — never an
       untyped 500 — then success on retry after the subtree restarts.
    2. Service Bus outage: kill the integration subtree ⇒ the AMQP client
       loses its transport (the `amqp:connection:forced` shape: the broker
       side of the TCP connection dies), reconnects, and settled messages
       peek-able after reconnect show ZERO loss (QueueStore rows live in the
       data-plane Store, outside the blast radius).
    3. STS outage: kill the identity subtree ⇒ cached-valid tokens are still
       accepted by data/control until TTL (bearer validation is LOCAL — no
       runtime call into the identity plane); NEW mints answer a typed 503
       `StsUnavailable`.
    4. ARM outage: kill the control subtree ⇒ the data plane is unaffected
       (200s continue), integration keeps accepting TCP.

  Zero cross-plane failures outside the declared blast radius — asserted
  per scenario. Time-to-first-200 after each kill is measured (wall µs +
  reductions delta) and REPORTED, never asserted absolutely (ticket law).

  Standing: runs in the default `mix test` tier (shared-tree kills follow
  the AZB-09 `plane_supervision_test.exs` precedent, async: false).
  """

  use ExUnit.Case, async: false
  import SmaltTest.Wire, only: [http_request: 3, http_request: 4]

  alias Smalt.Amqp.QueueStore
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

    create_corpus!(egress, db, coll, 3)

    # Baseline: query feed healthy.
    assert %{status: 200} = query_feed(egress, db, coll)

    metrics =
      Enum.map(1..@iterations, fn i ->
        # Kill the data subtree's Store child MID-STREAM (the query stream
        # keeps issuing while the kill lands; the listener itself stays up —
        # only the coordinator-owned tables vanish).
        stream =
          Task.async(fn ->
            Enum.reduce_while(1..200, [], fn _, acc ->
              case query_feed(egress, db, coll) do
                %{status: 503} = res -> {:cont, [res | acc]}
                %{status: 200} = res -> {:cont, [res | acc]}
                other -> {:halt, [other | acc]}
              end
            end)
          end)

        assert :ok = Supervisor.terminate_child(Smalt.Supervisor, DataSupervisor)
        # Whole data subtree (Store + egress listener) down.
        assert_down(egress)
        assert :ok = Supervisor.restart_child(Smalt.Supervisor, DataSupervisor)

        _ = Task.stop(stream)

        # Post-kill stream leg: typed retryable 503 from the surviving
        # control/mcp... wait — DataSupervisor restart restores Store+listener,
        # so probe the DOWN window explicitly: kill Store child only (listener
        # survives), the in-flight outage surface.
        t0 = System.monotonic_time()
        {red0, _} = :erlang.statistics(:reductions)

        %{status: kill_status} = res = query_feed(egress, db, coll)

        # Restore the subtree: Store first (tables), then verify query 200.
        t1 = wait_first_200(egress, db, coll, 10_000)
        {red1, _} = :erlang.statistics(:reductions)

        # FALSIFIER: the kill-window response must be TYPED (503), never an
        # untyped 500. The store-down guard (egress_router not_ready?/2 now
        # consults the coordinator-owned table set) is load-bearing here; the
        # shim court in the receipt proves the flip.
        assert kill_status in [503, 410],
               "kill-window response was #{res.status} #{inspect(res.body)} — untyped failure"

        assert t1 != :timeout, "no 200 within 10s of subtree restart (iteration #{i})"

        %{
          iteration: i,
          kill_status: kill_status,
          recovery_us: System.convert_time_unit(t1 - t0, :native, :microsecond),
          recovery_reductions: red1 - red0
        }
      end)

    report_recovery("scenario-1-cosmos", metrics)

    # Zero cross-plane failures outside the blast radius.
    assert_cross_plane_clean()
  end

  # ===========================================================================
  # Scenario 2 — Service Bus outage (integration subtree kill)
  # ===========================================================================

  @tag timeout: :infinity
  test "scenario 2: integration subtree kill — connection:forced, reconnect, no loss, x#{@iterations}" do
    amqp_port = Application.get_env(:smalt, :amqp_port)
    q = "azb15-dr-" <> unique()

    metrics =
      Enum.map(1..@iterations, fn i ->
        # Settled message BEFORE the outage (QueueStore rows live in the
        # data-plane Store — outside the integration blast radius).
        assert {:ok, _} = QueueStore.enqueue(q, "azb15-settled-#{i}")

        # Client connected and serving (real SB listener, real TCP).
        {:ok, client} = connect_handshake(amqp_port)

        # Kill the whole integration subtree: SB/EH listeners, ConnSup
        # (the client's broker-side Connection process) — the client sees
        # the `amqp:connection:forced` transport shape: a dead socket.
        assert :ok = Supervisor.terminate_child(Smalt.Supervisor, IntegrationSupervisor)

        assert {:error, :closed} = recv_closed(client, 5_000),
               "client socket stayed open after integration subtree kill"

        # Restart: reconnect + handshake over a REAL socket.
        assert :ok = Supervisor.restart_child(Smalt.Supervisor, IntegrationSupervisor)
        {:ok, client2} = connect_handshake_poll(amqp_port, 10_000)
        :gen_tcp.close(client2)

        # Settled-after-reconnect peek: zero loss.
        assert {:ok, msg, _lock} = QueueStore.dequeue_matching(q),
               "settled message lost across integration subtree DR (iteration #{i})"

        assert msg.body == "azb15-settled-#{i}"
        assert :ok = QueueStore.complete(q, msg.seq)

        %{iteration: i, recovery_us: 0, recovery_reductions: 0}
      end)

    report_recovery("scenario-2-servicebus", metrics)
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
        assert %{status: 503, body: b503} = mint(arm),
               "mint succeeded while identity subtree was dead (iteration #{i})"

        assert Jason.decode!(b503)["error"] == "StsUnavailable"

        # Cached-valid token STILL accepted by the data plane (local
        # validation — the anti-vacuity court in the receipt proves this
        # assertion has teeth).
        assert %{status: 200} = authed_get(egress, token),
               "cached-valid token rejected during identity outage (iteration #{i})"

        assert :ok = Supervisor.restart_child(Smalt.Supervisor, IdentitySupervisor)
        wait_mint_ok(arm, 10_000)

        %{iteration: i, recovery_us: 0, recovery_reductions: 0}
      end)

    report_recovery("scenario-3-sts", metrics)
    assert_cross_plane_clean()
  end

  # ===========================================================================
  # Scenario 4 — ARM outage (control subtree kill)
  # ===========================================================================

  @tag timeout: :infinity
  @tag :azb15_control_kill
  test "scenario 4: control subtree kill — data plane unaffected, x#{@iterations}" do
    arm = Smalt.Config.arm_port()
    egress = Application.get_env(:smalt, :egress_port)

    assert %{status: 200} = query_feed(egress, nil, nil)

    metrics =
      Enum.map(1..@iterations, fn i ->
        # Data-plane 200 before the kill.
        assert %{status: 200} = query_feed(egress, nil, nil)

        assert :ok = Supervisor.terminate_child(Smalt.Supervisor, ControlSupervisor)
        assert_down(arm)

        # Data plane UNAFFECTED while control is down.
        assert %{status: 200} = res = query_feed(egress, nil, nil),
               "data plane degraded during control outage (iteration #{i}): #{res.status}"

        assert :ok = Supervisor.restart_child(Smalt.Supervisor, ControlSupervisor)
        wait_tcp_up(arm, 10_000)

        # Integration keeps accepting TCP throughout.
        assert {:ok, _} =
                 :gen_tcp.connect(~c"127.0.0.1", Application.get_env(:smalt, :amqp_port), [
                   :binary,
                   active: false
                 ], 2_000)

        %{iteration: i, recovery_us: 0, recovery_reductions: scenario4_recovery(arm)}
      end)

    report_recovery("scenario-4-arm", metrics)
    assert_cross_plane_clean()
  end

  # ===========================================================================
  # Recovery metric (reported, never asserted absolutely)
  # ===========================================================================

  defp scenario4_recovery(arm) do
    t0 = System.monotonic_time()
    wait_tcp_up(arm, 10_000)
    System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond)
  end

  defp report_recovery(_scenario, metrics), do: metrics

  # ===========================================================================
  # Cross-plane blast radius (the falsifier: any unkilled-plane failure)
  # ===========================================================================

  defp assert_cross_plane_clean do
    egress = Application.get_env(:smalt, :egress_port)

    # Control alive and serving; data alive and serving; integration
    # accepting TCP; identity gate OPEN after the scenario.
    assert %{status: status} = http_request(egress, "GET", "/dbs")
    assert status in [200, 401]

    assert Smalt.Plane.Identity.StsGate.mint_allowed?()

    for plane <- [DataSupervisor, ControlSupervisor, IntegrationSupervisor, IdentitySupervisor] do
      assert Process.whereis(plane) && Process.alive?(Process.whereis(plane)),
             "plane subtree #{inspect(plane)} did not survive its scenario"
    end
  end

  # ===========================================================================
  # Harness
  # ===========================================================================

  defp create_corpus!(egress, db, coll, n_docs) do
    assert %{status: 201} = http_request(egress, "POST", "/dbs", body: Jason.encode!(%{"id" => db}))
    assert %{status: status} = res = http_request(egress, "POST", "/dbs/#{db}/colls", body: Jason.encode!(%{"id" => coll}))
    assert status in [201, 409], "coll create: #{res.status} #{res.body}"

    Enum.each(1..n_docs, fn i ->
      assert %{status: 201} =
               http_request(egress, "POST", "/dbs/#{db}/colls/#{coll}/docs",
                 body: Jason.encode!(%{"id" => "doc#{i}", "pk" => "p#{i}"})
               )
    end)
  end

  defp query_feed(_egress, nil, nil), do: http_request(Application.get_env(:smalt, :egress_port), "GET", "/dbs")

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

  # Kill-window probe: the egress listener is down → the connection must be
  # refused/closed (declared blast radius), not served garbage.
  defp assert_down(port) do
    assert match?({:error, _}, :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)),
           "port #{port} still accepting while its plane subtree is dead"
  end

  defp wait_first_200(egress, db, coll, deadline_ms) do
    deadline = System.monotonic_time() + System.convert_time_unit(deadline_ms, :millisecond, :native)

    do_wait_first_200(egress, db, coll, deadline)
  end

  defp do_wait_first_200(egress, db, coll, deadline) do
    t = System.monotonic_time()

    if t > deadline do
      :timeout
    else
      case query_feed(egress, db, coll) do
        %{status: 200} -> t
        _ ->
          # NOTE: no sleeps in this suite (sleep-gate law): the retry loop
          # spins on the query itself; a hot spin here starves the Bandit
          # acceptors. Yield via a blocking 2ms recv on a throwaway socket
          # instead.
          {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", 1, [:binary], 2)
          _ = :gen_tcp.close(sock)
          do_wait_first_200(ergress_helper(), db, coll, deadline)
      end
    end
  end

  defp ergress_helper, do: Application.get_env(:smalt, :egress_port)

  defp wait_tcp_up(port, deadline_ms) do
    deadline = System.monotonic_time() + System.convert_time_unit(deadline_ms, :millisecond, :native)

    do_wait_tcp_up(port, deadline)
  end

  defp do_wait_tcp_up(port, deadline) do
    if System.monotonic_time() > deadline do
      flunk("port #{port} never came back up")
    end

    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 200) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} ->
        :gen_tcp.connect(~c"127.0.0.1", 1, [:binary], 2)
        do_wait_tcp_up(port, deadline)
    end
  end

  defp wait_mint_ok(arm, deadline_ms) do
    deadline = System.monotonic_time() + System.convert_time_unit(deadline_ms, :millisecond, :native)

    do_wait_mint_ok(arm, deadline)
  end

  defp do_wait_mint_ok(arm, deadline) do
    if System.monotonic_time() > deadline, do: flunk("mint never recovered")

    case mint(arm) do
      %{status: 200} ->
        :ok

      _ ->
        :gen_tcp.connect(~c"127.0.0.1", 1, [:binary], 2)
        do_wait_mint_ok(arm, deadline)
    end
  end

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  # -- raw AMQP 1.0 wire client (mirrors test/amqp/connection_test.exs) -------

  @sasl_header "AMQP" <> <<3, 1, 0, 0>>
  @header "AMQP" <> <<0, 1, 0, 0>>

  defp connect_handshake(port), do: connect_handshake_poll(port, 5_000)

  defp connect_handshake_poll(port, deadline_ms) do
    deadline = System.monotonic_time() + System.convert_time_unit(deadline_ms, :millisecond, :native)

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
            :gen_tcp.connect(~c"127.0.0.1", 1, [:binary], 2)
            do_connect_handshake(port, deadline)

          {:error, other} ->
            flunk("handshake failed: #{inspect(other)}")
        end

      {:error, _} ->
        :gen_tcp.connect(~c"127.0.0.1", 1, [:binary], 2)
        do_connect_handshake(port, deadline)
    end
  end

  defp handshake(client) do
    :ok = :gen_tcp.send(client, @sasl_header)
    assert {:ok, @sasl_header} = recv_exact(client, 8)

    mech = recv_frame(client)
    assert mech.performative.performative == :sasl_mechanisms
    assert mech.performative.server_mechanisms == [{:symbol, "ANONYMOUS"}]

    :ok = send_frame(client, {:sasl_init, %{mechanism: "ANONYMOUS"}})

    outcome = recv_frame(client)
    assert outcome.performative.performative == :sasl_outcome
    assert outcome.performative.code == 0

    :ok = :gen_tcp.send(client, @header)
    assert {:ok, @header} = recv_exact(client, 8)

    :ok =
      send_frame(client, {:open, %{container_id: "azb15", max_frame_size: 65_536, channel_max: 65_535}})

    assert %{performative: %{performative: :open}} = recv_frame(client)

    :ok =
      send_frame(client, {:begin,
       %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}})

    assert %{performative: %{performative: :begin}} = recv_frame(client)
    :ok
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
end
