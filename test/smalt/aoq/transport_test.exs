defmodule Smalt.Aoq.TransportTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Chicago tests for the AoQ phase-1 transport (LANE-20): real loopback UDP
  echo over real `:socket` datagrams — no mocks, no sleeps. Round-trips are
  bounded polls on real observables (`SmaltTest.AssertEventually` /
  deadline-checked `Transport.recv/3`).
  """

  alias Smalt.Aoq.Transport

  @loopback "127.0.0.1"

  defp start_echo_server do
    {:ok, srv} = :socket.open(:inet, :dgram, :udp)
    :ok = :socket.bind(srv, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})

    {:ok, %{port: port}} = :socket.sockname(srv)

    parent = self()

    pid =
      Process.spawn(fn ->
        echo_loop(srv, parent)
      end, [])

    {pid, srv, port}
  end

  # Echo loop: blocks in recvmsg (runtime owns the wait — no sleep), echoes
  # the datagram back over the same socket.
  defp echo_loop(srv, parent) do
    case :socket.recvmsg(srv, 2048, 0, 5_000) do
      {:ok, %{iov: iovec} = msg} ->
        payload = :erlang.iolist_to_binary(iovec)

        case :socket.sendmsg(srv, %{iov: [:erlang.iolist_to_binary(payload)], addr: msg.addr}) do
          {:ok, _sent} -> :ok
          _ -> :ok
        end

        send(parent, {:echoed, payload})
        echo_loop(srv, parent)

      _ ->
        :ok
    end
  end

  defp with_echo_server(fun) do
    {pid, srv, port} = start_echo_server()

    try do
      fun.(port)
    after
      Process.exit(pid, :kill)
      :socket.close(srv)
    end
  end

  test "iovec send round-trips through a real loopback UDP echo" do
    with_echo_server(fn port ->
      {:ok, sock} = Transport.open(@loopback, port)

      header = :binary.copy(<<0>>, 64)
      body = <<"aoq-phase1-iovec-payload">>
      {:ok, [header, body]} = Smalt.Aoq.Frame.encode(header, body)

      assert {:ok, bytes} = Transport.send(sock, [header, body])
      assert bytes == 64 + byte_size(body)

      # Bounded poll on a real observable: the echoed datagram.
      assert {:ok, echoed} = Transport.recv(sock, 2048, timeout: 2_000)
      assert echoed == header <> body
      assert byte_size(echoed) >= 65

      # Second datagram on the same connected socket: 5-tuple reuse.
      {:ok, frame2} = Smalt.Aoq.Frame.encode(:binary.copy(<<1>>, 64), <<"second">>)
      iovec2 = frame2
      assert {:ok, _} = Transport.send(sock, iovec2)
      assert {:ok, echoed2} = Transport.recv(sock, 2048, timeout: 2_000)
      assert echoed2 == IO.iodata_to_binary(iovec2)
    end)
  end

  test "send on a closed socket is a typed refusal, never a crash" do
    {:ok, sock} = Transport.open(@loopback, 53_535)
    Transport.close(sock)

    header = :binary.copy(<<2>>, 64)

    assert {:error, {:transport_refusal, reason}} =
             Transport.send(sock, [header, <<"x">>])

    assert reason != nil
  end

  test "recv past the deadline is a typed refusal (bounded poll, no sleep)" do
    # An unbound-to-anything peer: open a connected socket to a port with no
    # echoer, then recv — the deadline bounds the poll.
    {:ok, sink} = :socket.open(:inet, :dgram, :udp)
    :ok = :socket.bind(sink, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
    {:ok, %{port: port}} = :socket.sockname(sink)

    {:ok, sock} = Transport.open(@loopback, port)
    assert {:error, {:transport_refusal, :recv_timeout}} =
             Transport.recv(sock, 2048, timeout: 300)

    Transport.close(sock)
    :socket.close(sink)
  end

  test "open to an unroutable address refuses typed (connect bounded poll)" do
    # UDP connect to a loopback port with no listener generally succeeds;
    # force a typed-failure path instead: bad host resolution.
    assert {:error, {:transport_refusal, _}} = Transport.open("not-a-host.invalid", 9000)
  end
end
