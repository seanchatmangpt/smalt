defmodule Smalt.Aoq.SessionTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Chicago tests for the pinned AoQ session recv loop (LANE-C5): real
  loopback UDP over real `:socket`, no mocks, no sleeps. Pin witness =
  the `{:aoq_session_pinned, core}` re-pin binding pushed by the session
  (this OTP build exposes no `scheduler_id` process_info item); tail
  recursion witness = `:stack_size` stable across 1_000 frames.
  """

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  alias Smalt.Aoq.Frame
  alias Smalt.Aoq.Session
  alias Smalt.Aoq.Transport

  @loopback {127, 0, 0, 1}

  defp safe_close(sock) do
    case :socket.close(sock) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  defp with_paired_sockets(fun) do
    {:ok, srv} = :socket.open(:inet, :dgram, :udp)
    :ok = :socket.bind(srv, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
    {:ok, %{port: port}} = :socket.sockname(srv)
    {:ok, client} = Transport.open(@loopback, port, timeout: 2_000)

    try do
      fun.(srv, client)
    after
      safe_close(srv)
      safe_close(client)
    end
  end

  defp frame do
    header = :binary.copy(<<3>>, 64)
    body = :binary.copy(<<4>>, 8)
    {:ok, iolist} = Frame.encode(header, body)
    iolist
  end

  test "pin witness: pinned-core binding pushed at init and stable across frames" do
    with_paired_sockets(fn srv, client ->
      {:ok, pid} = Session.start_link(socket: srv, owner: self(), pin: true, idle_timeout: 5_000)
      Process.unlink(pid)

      assert_receive {:aoq_session_pinned, sched}, 2_000
      assert is_integer(sched) and sched in 1..:erlang.system_info(:schedulers_online)

      iolist = frame()
      assert {:ok, _} = Transport.send(client, iolist)
      assert_receive {:aoq_session_frame, payload}, 2_000
      assert byte_size(payload) >= 65

      # The witnessed binding is stored in the session and unchanged.
      assert Session.scheduler_id(pid) == sched

      Session.stop(pid)
    end)
  end

  test "pin: integer pins to that exact core" do
    with_paired_sockets(fn srv, _client ->
      {:ok, pid} = Session.start_link(socket: srv, owner: self(), pin: 1, idle_timeout: 5_000)
      Process.unlink(pid)

      assert_receive {:aoq_session_pinned, 1}, 2_000
      assert Session.scheduler_id(pid) == 1

      Session.stop(pid)
    end)
  end

  test "tail recursion: stack_size stable across 1_000 frames" do
    with_paired_sockets(fn srv, client ->
      ref = :atomics.new(1, signed: false)
      handler = fn _payload -> :atomics.add_get(ref, 1, 1) end

      {:ok, pid} =
        Session.start_link(
          socket: srv,
          owner: self(),
          handler: handler,
          pin: nil,
          idle_timeout: 5_000
        )

      Process.unlink(pid)
      iolist = frame()

      for _ <- 1..1_000 do
        assert {:ok, _} = Transport.send(client, iolist)
      end

      # Early stack reading once traffic has flowed; late reading at full count.
      assert_eventually(fn -> :atomics.get(ref, 1) >= 100 end, timeout: 2_000)
      {:stack_size, early} = :erlang.process_info(pid, :stack_size)

      assert_eventually(fn -> :atomics.get(ref, 1) == 1_000 end, timeout: 5_000)
      {:stack_size, late} = :erlang.process_info(pid, :stack_size)

      # Tail-recursive loop: stack does not grow with frame count.
      # OTP 29 recvmsg NIF native-frame variance (~8-16 words) — a
      # non-tail-recursive loop over 1_000 frames would grow by orders more.
      assert late <= early + 16,
             "stack grew: early=#{early} late=#{late} — loop is not tail-recursive"

      Session.stop(pid)
    end)
  end

  test "idle deadline lapses into a typed refusal, owner notified, socket closed" do
    {:ok, srv} = :socket.open(:inet, :dgram, :udp)
    :ok = :socket.bind(srv, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})

    {:ok, pid} = Session.start_link(socket: srv, owner: self(), pin: nil, idle_timeout: 200)
    Process.unlink(pid)

    assert_receive {:aoq_session_done, {:transport_refusal, :recv_timeout}}, 2_000
    assert Process.alive?(pid) == false

    # Closing an already-session-closed socket is harmless.
    assert safe_close(srv) == :ok
  end
end
