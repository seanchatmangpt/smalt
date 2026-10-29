# SCVD backpressure audit MED-4 remediation court (test/internal, internal tier).
#
# Chicago discipline: a REAL Smalt.Amqp.Listener on an ephemeral loopback port,
# a REAL DynamicSupervisor, and REAL :gen_tcp connections — no mocks. The cap
# is tightened via `config :smalt, :amqp_max_connections` (typed
# `Smalt.Amqp.Listener.max_connections/0`, default 10_000 — no current test
# gets near it), and the refusal is observed through the real telemetry event
# [:smalt, :amqp, :connection_refused] plus the real socket close (EOF).
#
# Context: solo (internal tier, in-process wire faces).

Code.require_file(Path.expand("../internal/poll_helper.exs", __DIR__))

defmodule Internal.AmqpListenerCapTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.Listener

  @cap 2
  @moduletag :cap

  setup do
    # Typed cap override — generous 10_000 default untouched in prod config.
    original = Application.get_env(:smalt, :amqp_max_connections)
    Application.put_env(:smalt, :amqp_max_connections, @cap)

    sup_name = Module.concat(__MODULE__, ConnSup)
    {:ok, sup} = DynamicSupervisor.start_link(name: sup_name)

    {:ok, _} =
      Listener.start_link(
        {:sb, 0, name: Module.concat(__MODULE__, ListenerSb), conn_sup: sup_name}
      )

    port = Listener.port(Module.concat(__MODULE__, ListenerSb))

    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      ref,
      [:smalt, :amqp, :connection_refused],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:conn_refused, metadata[:lane]})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(ref)
      restore(original)
      if pid = Process.whereis(Module.concat(__MODULE__, ListenerSb)),
        do: Process.exit(pid, :kill)

      if pid = Process.whereis(sup_name), do: Process.exit(pid, :kill)
    end)

    %{port: port, sup: sup_name, listener: Module.concat(__MODULE__, ListenerSb)}
  end

  defp restore(nil), do: :ok
  defp restore(v), do: Application.put_env(:smalt, :amqp_max_connections, v)

  test "max_connections/0 reads the typed cap (default 10_000 when unconfigured)" do
    Application.delete_env(:smalt, :amqp_max_connections)

    assert Listener.max_connections() == 10_000
  after
    Application.put_env(:smalt, :amqp_max_connections, @cap)
  end

  test "cap refuses beyond-ceiling connections typed (telemetry + close) while at-cap connections keep working",
       %{port: port, sup: sup, listener: listener} do
    assert Listener.max_connections() == @cap

    # Fill the cap with REAL connections. Each accepted connection is a real
    # Smalt.Amqp.Connection process; before the AMQP open it sits in its recv
    # pump (300s idle recv timeout), so it stays alive while the raw client
    # sends nothing.
    clients =
      for _ <- 1..@cap do
        {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
        sock
      end

    await_children(sup, @cap)

    # At-cap connections are alive under the real supervisor.
    assert %{active: @cap} = DynamicSupervisor.count_children(sup)

    # One more REAL connection: accepted, then refused — socket closed, typed
    # telemetry counter event emitted.
    {:ok, refused} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    assert_receive {:conn_refused, :sb}, 5_000

    # The refused socket is closed by the listener (EOF on recv, no data).
    assert {:error, :closed} = :gen_tcp.recv(refused, 1, 5_000)

    # The supervisor did NOT grow past the cap.
    await_children(sup, @cap)
    assert %{active: @cap} = DynamicSupervisor.count_children(sup)

    # Listener still accepting: a subsequent connect is accepted (then also
    # refused typed, since the cap is still full).
    {:ok, sock2} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    assert_receive {:conn_refused, :sb}, 5_000
    assert {:error, :closed} = :gen_tcp.recv(sock2, 1, 5_000)

    # Listener process itself never crashed.
    assert Process.whereis(listener) |> is_pid()

    # Drain: free the slots, the next connection is admitted again (typed
    # refusal is not sticky).
    Enum.each(clients, fn sock -> :gen_tcp.close(sock) end)

    await_children(sup, 0)

    {:ok, sock3} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    await_children(sup, 1)
    :gen_tcp.close(sock3)

    refute_receive {:conn_refused, :sb}
  end

  defp await_children(sup, n) do
    case SmaltTest.Internal.Poll.eventually(
           fn -> if DynamicSupervisor.count_children(sup)[:active] == n, do: {:ok, n}, else: {:waiting, n} end,
           timeout_ms: 5_000
         ) do
      {:ok, _} -> :ok
      {:timeout, _} -> flunk("expected #{n} active connections, got #{inspect(DynamicSupervisor.count_children(sup))}")
    end
  end
end
