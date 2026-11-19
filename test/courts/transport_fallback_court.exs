defmodule TransportFallbackCourt do
  @moduledoc """
  FNOX-SJ-QUIC-4 court: QUIC-to-h2 selector over real listeners.

  Run: mix test test/courts/transport_fallback_court.exs
  Needs certs: SMALT_CERT_DIR=/tmp/lane4-certs scripts/gen_dev_cert.sh
  """

  use ExUnit.Case, async: false

  alias Smalt.Aoq.Quic
  alias Smalt.Aoq.Quic.Certs
  alias Smalt.Aoq.Quic.Listener
  alias Smalt.Aoq.Transport.Selector

  @cert_dir "/tmp/lane4-certs"
  @payload "selector-court-payload"

  setup do
    unless Quic.Nif.loaded?() do
      flunk("QUIC NIF not loaded: #{inspect(Quic.Nif.load_status())}")
    end

    {:ok, ca_der} = Certs.pem_to_der!(Path.join(@cert_dir, "ca-cert.pem"))
    {:ok, cert_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-cert.pem"))
    {:ok, key_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-key.pem"))
    {:ok, ca_der: ca_der, cert_der: cert_der, key_der: key_der}
  end

  test "QUIC up: result.transport == :quic and payload echoes", ctx do
    port = free_udp_port()
    name = :"selector_court_listener_#{System.unique_integer([:positive])}"

    spec =
      Listener.child_spec(
        name: name,
        port: port,
        ca_der: ctx.ca_der,
        cert_der: ctx.cert_der,
        key_der: ctx.key_der
      )

    assert {:ok, _} = Supervisor.start_child(Smalt.Supervisor, spec)

    on_exit(fn ->
      Supervisor.terminate_child(Smalt.Supervisor, name)
      Supervisor.delete_child(Smalt.Supervisor, name)
    end)

    assert eventually(fn -> Listener.status(name) == :ready end)

    {h2_listen, h2_port} = start_h2_server(ctx)

    session =
      eventually_value(fn ->
        case Selector.connect(
               ca_der: ctx.ca_der,
               quic: {"127.0.0.1", port},
               h2: {"127.0.0.1", h2_port}
             ) do
          {:ok, %{transport: :quic}} = ok -> ok
          other -> other
        end
      end)

    assert {:ok, %{transport: :quic, fallback_reason: nil} = s} = session
    assert :ok = Selector.send(s, @payload)
    assert {:ok, @payload} = Selector.recv(s, 10_000)
    Selector.close(s)
    :ssl.close(h2_listen)
  end

  test "UDP closed, TCP h2 up: result.transport == :h2 and payload echoes", ctx do
    udp_port = free_udp_port()
    {h2_listen, h2_port} = start_h2_server(ctx)

    assert {:ok, %{transport: :h2, fallback_reason: {:quic_refusal, _}} = s} =
             Selector.connect(
               ca_der: ctx.ca_der,
               quic: {"127.0.0.1", udp_port},
               h2: {"127.0.0.1", h2_port}
             )

    assert :ok = Selector.send(s, @payload)
    assert {:ok, @payload} = Selector.recv(s, 10_000)
    Selector.close(s)
    :ssl.close(h2_listen)
  end

  test "bad CA is a typed error, not a fallback", ctx do
    udp_port = free_udp_port()
    {h2_listen, h2_port} = start_h2_server(ctx)

    assert {:error, {:selector_refusal, {:bad_ca, _}}} =
             Selector.connect(
               ca_der: <<0, 1, 2, 3, 4, 5>>,
               quic: {"127.0.0.1", udp_port},
               h2: {"127.0.0.1", h2_port}
             )

    :ssl.close(h2_listen)
  end

  # Real TCP TLS listener negotiating ALPN h2; echoes one payload per connection.
  defp start_h2_server(ctx) do
    {:ok, listen} =
      :ssl.listen(0,
        certfile: String.to_charlist(Path.join(@cert_dir, "quic-cert.pem")),
        keyfile: String.to_charlist(Path.join(@cert_dir, "quic-key.pem")),
        reuseaddr: true,
        active: false,
        mode: :binary,
        alpn_preferred_protocols: ["h2"]
      )

    {:ok, {_, port}} = :ssl.sockname(listen)
    _ = ctx
    spawn(fn -> accept_loop(listen) end)
    {listen, port}
  end

  defp accept_loop(listen) do
    case :ssl.transport_accept(listen, 30_000) do
      {:ok, tsock} ->
        case :ssl.handshake(tsock, 10_000) do
          {:ok, sock} ->
            case :ssl.recv(sock, 0, 10_000) do
              {:ok, data} -> :ssl.send(sock, data)
              _ -> :ok
            end

          _ ->
            :ok
        end

        accept_loop(listen)

      _ ->
        :ok
    end
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
