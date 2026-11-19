defmodule Smalt.Aoq.QuicSessionTest do
  @moduledoc """
  FNOX-SJ-QUIC-2: N real QUIC connections, each owned by a distinct
  :gen_statem session; one session crash leaves the others serving.
  Needs certs in /tmp/lane4-certs (scripts/gen_dev_cert.sh) and a loaded NIF.
  """

  use ExUnit.Case, async: false

  alias Smalt.Aoq.Quic
  alias Smalt.Aoq.Quic.Certs
  alias Smalt.Aoq.Quic.Listener
  alias Smalt.Aoq.QuicSession.Supervisor, as: SessionSup

  @cert_dir "/tmp/lane4-certs"

  setup do
    unless Quic.Nif.loaded?() do
      flunk("QUIC NIF not loaded: #{inspect(Quic.Nif.load_status())}")
    end

    {:ok, ca_der} = Certs.pem_to_der!(Path.join(@cert_dir, "ca-cert.pem"))
    {:ok, cert_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-cert.pem"))
    {:ok, key_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-key.pem"))
    port = free_udp_port()
    id = System.unique_integer([:positive])
    lname = :"quic_session_listener_#{id}"
    sname = :"quic_session_sup_#{id}"

    start_supervised!(%{
      id: sname,
      start: {SessionSup, :start_link, [[name: sname]]},
      type: :supervisor
    })

    start_supervised!(
      Listener.child_spec(
        name: lname,
        port: port,
        ca_der: ca_der,
        cert_der: cert_der,
        key_der: key_der,
        handler: SessionSup.handler(sname)
      )
    )

    assert eventually(fn -> Listener.status(lname) == :ready end)
    {:ok, sup: sname, port: port, ca_der: ca_der}
  end

  test "3 connections get 3 distinct gen_statem sessions; one kill leaves 2 serving", ctx do
    clients = for i <- 1..3, do: client(ctx, "hello-#{i}")

    assert eventually(fn -> length(SessionSup.sessions(ctx.sup)) == 3 end)
    pids = SessionSup.sessions(ctx.sup)
    assert length(Enum.uniq(pids)) == 3

    for pid <- pids do
      assert {state, %{conn: conn}} = :sys.get_state(pid)
      assert state in [:awaiting_stream, :serving]
      assert is_reference(conn)
    end

    [victim | _] = pids
    ref = Process.monitor(victim)
    Process.exit(victim, :kill)
    assert_receive {:DOWN, ^ref, :process, ^victim, :killed}, 2_000

    survivors = SessionSup.sessions(ctx.sup)
    assert length(survivors) == 2
    refute victim in survivors

    ok =
      Enum.count(clients, fn stream ->
        :ok = Quic.stream_send(stream, "after-kill")
        Quic.stream_recv(stream, 2_000) == {:ok, "after-kill"}
      end)

    assert ok == 2
  end

  # Opens a connection, performs one echo so the session is serving, returns the stream.
  defp client(ctx, payload) do
    {:ok, cli} = Quic.open(0, ctx.ca_der)

    {:ok, conn} =
      eventually_value(fn -> Quic.connect(cli, "127.0.0.1:#{ctx.port}", "localhost") end)

    {:ok, stream} = Quic.stream_open(conn)
    :ok = Quic.stream_send(stream, payload)
    assert {:ok, ^payload} = Quic.stream_recv(stream, 10_000)
    stream
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
