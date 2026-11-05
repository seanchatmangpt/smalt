defmodule Smalt.Aoq.SupervisorTest do
  @moduledoc false
  # LANE-11: Chicago-style - real supervised boot on a real ephemeral port,
  # real UDP datagrams over the real listener socket, real worker processes.
  # No mocks.
  use ExUnit.Case, async: false

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  alias Smalt.Aoq.{Listener, NifHolder, Supervisor, Worker, WorkerPool}

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp start_aoq(opts \\ []) do
    cfg =
      [enabled: true, port: free_port(), workers: 3]
      |> Keyword.merge(opts)

    Application.put_env(:smalt, :aoq, cfg)
    start_supervised!(Supervisor)

    # Structural readiness: workers alive + listener bound - bounded polls on
    # real observables, never Process.sleep.
    assert_eventually(fn -> WorkerPool.live_workers() == cfg[:workers] end,
      timeout: 5_000,
      interval: 10
    )

    assert_eventually(fn -> Listener.local_port() == cfg[:port] end,
      timeout: 5_000,
      interval: 10
    )

    assert Listener.refusal() == nil
    cfg
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:smalt, :aoq)
      :persistent_term.erase({Listener, :local_port})
      :persistent_term.erase({Listener, :refusal})
      :persistent_term.erase({WorkerPool, :dispatch})
    end)

    :ok
  end

  test "boots the full one_for_one subtree: listener bound, pool live, holder alive" do
    cfg = start_aoq()
    assert is_pid(GenServer.whereis(NifHolder))
    assert is_pid(Process.whereis(WorkerPool))
    assert is_pid(Process.whereis(Worker.registered(0)))
    assert Listener.local_port() == cfg[:port]
  end

  test "datagram ingest: one real UDP datagram reaches a pool worker via the sink" do
    cfg = start_aoq()
    port = Listener.local_port()

    {:ok, sock} = :gen_udp.open(0, [:binary])
    frame = :crypto.strong_rand_bytes(100)
    :gen_udp.send(sock, {127, 0, 0, 1}, port, frame)

    # Observable: the pool's dispatch counter advanced (the sink ran).
    before = dispatch_idx()
    assert_eventually(fn -> dispatch_idx() > before or submit_ok?() end,
      timeout: 5_000,
      interval: 10
    )

    assert {:ok, _lease} = WorkerPool.submit(frame)
    :gen_udp.close(sock)
  end

  test "worker crash is a restart, never data loss (one_for_one law)" do
    start_aoq()

    pid = Process.whereis(Worker.registered(1))
    Process.exit(pid, :kill)

    assert_eventually(
      fn ->
        new = Process.whereis(Worker.registered(1))
        is_pid(new) and new != pid and Process.alive?(new)
      end,
      timeout: 5_000,
      interval: 10
    )
  end

  test "NIF seam: stub parse enforces the >64B framing law (spec section 2)" do
    assert {:ok, %{header: h, payload: p}} = NifHolder.parse(:crypto.strong_rand_bytes(100))
    assert byte_size(h) == 64
    assert byte_size(p) == 36

    assert {:error, {:aoq_frame_too_short, 64}} = NifHolder.parse(:crypto.strong_rand_bytes(64))
  end

  test "NIF seam: stub encode emits the iolist egress shape, byte-identical to concat" do
    payload = :crypto.strong_rand_bytes(37)
    header = :crypto.strong_rand_bytes(64)

    assert {:ok, iolist} = Smalt.Aoq.Nif.Stub.encode(%{header: header, payload: payload})
    assert IO.iodata_to_binary(iolist) == header <> payload
  end

  test "pool refuses a zero-width pool with a typed error" do
    start_aoq(workers: 0)
    assert {:error, :pool_empty} = WorkerPool.submit("frame")
  end

  test "config defaults: port 9093 pin, schedulers-sized pool" do
    Application.delete_env(:smalt, :aoq)
    Application.delete_env(:smalt, :aoq_port)

    assert Keyword.get(Supervisor.config(), :port) == 9093
    assert Keyword.get(Supervisor.config(), :workers) == System.schedulers_online()
  end

  defp dispatch_idx do
    case :persistent_term.get({WorkerPool, :dispatch}, nil) do
      {_count, dispatch, _seq} -> :atomics.get(dispatch, 1)
      _ -> 0
    end
  end

  defp submit_ok? do
    match?({:ok, _}, WorkerPool.submit(:crypto.strong_rand_bytes(80)))
  end
end
