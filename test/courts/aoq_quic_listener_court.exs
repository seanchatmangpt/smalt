defmodule AoqQuicListenerCourt do
  @moduledoc """
  FNOX-SJ-QUIC-1 court: a supervised QUIC listener under the app supervisor
  accepts a real client, echoes bytes, and is restarted after a kill.

  Run: mix test test/courts/aoq_quic_listener_court.exs
  Needs certs: SMALT_CERT_DIR=/tmp/lane4-certs scripts/gen_dev_cert.sh
  """

  use ExUnit.Case, async: false

  alias Smalt.Aoq.Quic
  alias Smalt.Aoq.Quic.Certs
  alias Smalt.Aoq.Quic.Listener

  @cert_dir "/tmp/lane4-certs"

  setup do
    unless Quic.Nif.loaded?() do
      flunk("QUIC NIF not loaded: #{inspect(Quic.Nif.load_status())}")
    end

    {:ok, ca_der} = Certs.pem_to_der!(Path.join(@cert_dir, "ca-cert.pem"))
    {:ok, cert_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-cert.pem"))
    {:ok, key_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-key.pem"))
    port = free_udp_port()
    name = :"quic_listener_court_#{System.unique_integer([:positive])}"

    spec =
      Listener.child_spec(
        name: name,
        port: port,
        ca_der: ca_der,
        cert_der: cert_der,
        key_der: key_der
      )

    assert {:ok, _} = Supervisor.start_child(Smalt.Supervisor, spec)

    on_exit(fn ->
      Supervisor.terminate_child(Smalt.Supervisor, name)
      Supervisor.delete_child(Smalt.Supervisor, name)
    end)

    {:ok, name: name, port: port, ca_der: ca_der}
  end

  test "client connects to supervised listener and bytes echo", ctx do
    assert eventually(fn -> Listener.status(ctx.name) == :ready end)
    assert echo(ctx) == payload()
  end

  test "killed listener is restarted by its supervisor and serves again", ctx do
    assert eventually(fn -> Listener.status(ctx.name) == :ready end)
    assert echo(ctx) == payload()

    old = Process.whereis(ctx.name)
    assert is_pid(old)
    Process.exit(old, :kill)

    assert eventually(fn ->
             new = Process.whereis(ctx.name)
             is_pid(new) and new != old and Listener.status(ctx.name) == :ready
           end)

    assert echo(ctx) == payload()
  end

  test "config-gated application child serves, survives a kill, and serves again", ctx do
    port = free_udp_port()
    name = :"quic_app_child_court_#{System.unique_integer([:positive])}"
    previous = Application.get_env(:smalt, :aoq_quic_listener)

    {:ok, cert_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-cert.pem"))
    {:ok, key_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-key.pem"))

    Application.put_env(:smalt, :aoq_quic_listener,
      name: name,
      port: port,
      ca_der: ctx.ca_der,
      cert_der: cert_der,
      key_der: key_der
    )

    on_exit(fn ->
      Supervisor.terminate_child(Smalt.Supervisor, name)
      Supervisor.delete_child(Smalt.Supervisor, name)

      if previous,
        do: Application.put_env(:smalt, :aoq_quic_listener, previous),
        else: Application.delete_env(:smalt, :aoq_quic_listener)
    end)

    assert [{Listener, opts}] = Smalt.Application.quic_listener_child()
    assert {:ok, _} = Supervisor.start_child(Smalt.Supervisor, Listener.child_spec(opts))
    app_ctx = %{ctx | port: port}

    assert eventually(fn -> Listener.status(name) == :ready end)
    assert echo(app_ctx) == payload()

    old = Process.whereis(name)
    Process.exit(old, :kill)

    assert eventually(fn ->
             new = Process.whereis(name)
             is_pid(new) and new != old and Listener.status(name) == :ready
           end)

    assert echo(app_ctx) == payload()
  end

  defp payload, do: "listener-court-payload"

  defp echo(ctx) do
    {:ok, cli} = Quic.open(0, ctx.ca_der)

    {:ok, conn} =
      eventually_value(fn -> Quic.connect(cli, "127.0.0.1:#{ctx.port}", "localhost") end)

    {:ok, stream} = Quic.stream_open(conn)
    :ok = Quic.stream_send(stream, payload())
    {:ok, back} = Quic.stream_recv(stream, 10_000)
    back
  end

  defp eventually_value(fun, deadline_ms \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll_value(fun, deadline)
  end

  defp poll_value(fun, deadline) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          other
        else
          :erlang.yield()
          poll_value(fun, deadline)
        end
    end
  end

  defp eventually(fun, deadline_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    result =
      try do
        fun.()
      catch
        :exit, _ -> false
      end

    cond do
      result -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true ->
        :erlang.yield()
        poll(fun, deadline)
    end
  end

  defp free_udp_port do
    {:ok, sock} = :gen_udp.open(0, mode: :binary)
    {:ok, port} = :inet.port(sock)
    :gen_udp.close(sock)
    port
  end
end
