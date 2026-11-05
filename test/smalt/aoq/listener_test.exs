defmodule Smalt.Aoq.ListenerTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Chicago tests for the AoQ datagram listener (LANE-C5): real loopback UDP
  datagrams over real `:socket` — no mocks, no sleeps. Readiness is the
  `local_port/0` observable polled via `SmaltTest.AssertEventually`; the
  frame witness is a test-owned receiver fed by the listener's `:sink`
  seam, plus one integration leg through the real WorkerPool.
  """

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  alias Smalt.Aoq.Frame
  alias Smalt.Aoq.Listener
  alias Smalt.Aoq.Transport

  @loopback {127, 0, 0, 1}

  defp client_to(port) do
    Transport.open(@loopback, port, timeout: 2_000)
  end

  defp safe_close(sock) do
    case :socket.close(sock) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  defp frame do
    header = :binary.copy(<<7>>, 64)
    body = :binary.copy(<<9>>, 8)
    {:ok, iolist} = Frame.encode(header, body)
    {iolist, header, body}
  end

  test "readiness via local_port (ephemeral bind)" do
    {:ok, pid} = Listener.start_link(port: 0, pin: nil, idle_timeout: 5_000)

    assert_eventually(fn -> Listener.local_port() != nil end, timeout: 2_000)
    port = Listener.local_port()
    assert is_integer(port) and port in 1..65_535
    assert Listener.refusal() == nil

    Listener.stop(pid)
  end

  test "datagram face hands a real loopback frame to a test-owned receiver" do
    ref = :atomics.new(1, signed: false)
    parent = self()

    sink = fn payload ->
      :atomics.add_get(ref, 1, 1)
      send(parent, {:aoq_frame, payload})
      {:ok, 0}
    end

    {:ok, pid} = Listener.start_link(port: 0, sink: sink, pin: nil, idle_timeout: 5_000)
    assert_eventually(fn -> Listener.local_port() != nil end, timeout: 2_000)
    port = Listener.local_port()

    {iolist, _header, _body} = frame()
    assert {:ok, sock} = client_to(port)
    assert {:ok, sent} = Transport.send(sock, iolist)
    assert sent == 72

    # AssertEventually witness at the test-owned receiver (atomics counter).
    assert_eventually(fn -> :atomics.get(ref, 1) >= 1 end, timeout: 2_000)

    assert_receive {:aoq_frame, payload}, 2_000
    assert byte_size(payload) >= 65

    Listener.stop(pid)
    safe_close(sock)
  end

  test "integration: real WorkerPool seq advances on a loopback frame" do
    start_supervised!({WorkerPool, workers: 2})
    assert_eventually(fn -> WorkerPool.live_workers() == 2 end, timeout: 2_000)

    {:ok, pid} = Listener.start_link(port: 0, pin: nil, idle_timeout: 5_000)
    assert_eventually(fn -> Listener.local_port() != nil end, timeout: 2_000)
    port = Listener.local_port()

    {_count, _dispatch, seq} = :persistent_term.get({WorkerPool, :dispatch})
    before = :atomics.get(seq, 1)

    {iolist, _header, _body} = frame()
    {:ok, sock} = client_to(port)
    assert {:ok, _} = Transport.send(sock, iolist)

    # Real observable: the pool's seq lease counter advanced via submit/1.
    assert_eventually(fn -> :atomics.get(seq, 1) > before end, timeout: 2_000)

    Listener.stop(pid)
    safe_close(sock)
  end

  test "bind to an occupied port records a typed refusal" do
    {:ok, holder} = :socket.open(:inet, :dgram, :udp)
    :ok = :socket.bind(holder, {:socket.sockaddr_in, {127, 0, 0, 1}, 0})
    {:ok, {:socket.sockaddr_in, _, occupied_port}} = :socket.sockname(holder)
    safe_close(holder)

    {:ok, pid} = Listener.start_link(port: occupied_port, pin: nil)
    Process.unlink(pid)

    assert_eventually(fn -> Listener.refusal() != nil end, timeout: 2_000)
    assert {:transport_refusal, _} = Listener.refusal()

    Process.exit(pid, :kill)
  end
end
