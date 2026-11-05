defmodule Smalt.Aoq.ListenerTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Chicago tests for the AoQ datagram listener (LANE-C5): real loopback UDP
  datagrams over real `:socket` — no mocks, no sleeps. Readiness is the
  per-listener `{:aoq_listener_bound, port}` witness (cfg `:report_to`)
  plus the `local_port/0` observable; the frame witness is a test-owned
  receiver fed by the listener's `:sink` seam, plus one integration leg
  through the real WorkerPool.
  """

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  alias Smalt.Aoq.Frame
  alias Smalt.Aoq.Listener
  alias Smalt.Aoq.Transport
  alias Smalt.Aoq.WorkerPool

  @loopback {127, 0, 0, 1}

  defp safe_close(sock) do
    case :socket.close(sock) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  # Unlink + guaranteed stop even on assertion failure (no orphan
  # listeners leaking a global persistent_term port across tests).
  defp with_listener(cfg, fun) do
    {:ok, pid} = Listener.start_link(cfg)
    Process.unlink(pid)

    try do
      fun.()
    after
      Listener.stop(pid)
    end
  end

  defp frame do
    header = :binary.copy(<<7>>, 64)
    body = :binary.copy(<<9>>, 8)
    {:ok, iolist} = Frame.encode(header, body)
    {iolist, header, body}
  end

  test "readiness: per-listener bound witness and local_port observable" do
    with_listener([port: 0, pin: nil, idle_timeout: 5_000, report_to: self()], fn ->
      assert_receive {:aoq_listener_bound, port}, 2_000
      assert is_integer(port) and port in 1..65_535

      assert_eventually(fn -> Listener.local_port() != nil end, timeout: 2_000)
      assert Listener.local_port() == port
      assert Listener.refusal() == nil
    end)
  end

  test "datagram face hands a real loopback frame to a test-owned receiver" do
    ref = :atomics.new(1, signed: false)
    parent = self()

    sink = fn payload ->
      :atomics.add_get(ref, 1, 1)
      send(parent, {:aoq_frame, payload})
      {:ok, 0}
    end

    with_listener([port: 0, sink: sink, pin: nil, idle_timeout: 5_000, report_to: self()], fn ->
      assert_receive {:aoq_listener_bound, port}, 2_000

      {iolist, _header, _body} = frame()
      assert {:ok, sock} = Transport.open(@loopback, port, timeout: 2_000)
      assert {:ok, sent} = Transport.send(sock, iolist)
      assert sent == 72

      # AssertEventually witness at the test-owned receiver (atomics counter).
      assert_eventually(fn -> :atomics.get(ref, 1) >= 1 end, timeout: 2_000)

      assert_receive {:aoq_frame, payload}, 2_000
      assert byte_size(payload) >= 65

      safe_close(sock)
    end)
  end

  test "integration: real WorkerPool seq advances on a loopback frame" do
    start_supervised!({WorkerPool, workers: 2})
    assert_eventually(fn -> WorkerPool.live_workers() == 2 end, timeout: 2_000)

    with_listener([port: 0, pin: nil, idle_timeout: 5_000, report_to: self()], fn ->
      assert_receive {:aoq_listener_bound, port}, 2_000

      {_count, _dispatch, seq} = :persistent_term.get({Smalt.Aoq.WorkerPool, :dispatch})
      before = :atomics.get(seq, 1)

      {iolist, _header, _body} = frame()
      {:ok, sock} = Transport.open(@loopback, port, timeout: 2_000)
      assert {:ok, _} = Transport.send(sock, iolist)

      # Real observable: the pool's seq lease counter advanced via submit/1.
      assert_eventually(fn -> :atomics.get(seq, 1) > before end, timeout: 2_000)

      safe_close(sock)
    end)
  end

  test "bind refusal records a typed refusal" do
    # Privileged port 1 as non-root: bind refuses (eacces) — deterministic
    # typed-refusal witness without depending on double-bind semantics.
    {:ok, pid} = Listener.start_link(port: 1, pin: nil)
    Process.unlink(pid)

    assert_eventually(fn -> Listener.refusal() != nil end, timeout: 2_000)
    assert {:transport_refusal, reason} = Listener.refusal()
    assert reason != nil

    Process.exit(pid, :kill)
  end
end
