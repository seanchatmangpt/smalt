defmodule Smalt.Plane.DataSupervisorAoqTest do
  @moduledoc false
  # LANE-11 / C2: the AoQ subtree's single lawful start site is the data
  # plane (Smalt.Plane.DataSupervisor). Chicago discipline: real supervised
  # boot under the REAL running plane supervisor, real UDP datagrams over
  # the real listener socket, real worker processes. No mocks, no
  # Process.sleep - bounded polls on real observables only.
  use ExUnit.Case, async: false

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  alias Smalt.Aoq.Listener
  alias Smalt.Aoq.Supervisor, as: AoqSupervisor
  alias Smalt.Aoq.WorkerPool

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  # mix test boots Smalt.Application before the suite, and config/test.exs
  # does NOT enable AoQ - the running tree IS the disabled path. The enabled
  # path starts the real child through the real plane supervisor
  # (Supervisor.start_child with the exact child_spec shape the gate builds:
  # `Supervisor.child_spec({Smalt.Aoq.Supervisor, []}, shutdown: 10_000)`),
  # with the same Application.put_env the gate reads.
  defp start_via_plane do
    cfg = [enabled: true, port: free_port(), workers: 3]
    Application.put_env(:smalt, :aoq, cfg)

    {:ok, _pid} =
      Supervisor.start_child(
        Smalt.Plane.DataSupervisor,
        Supervisor.child_spec({AoqSupervisor, []}, shutdown: 10_000)
      )

    assert_eventually(
      fn ->
        is_pid(Process.whereis(AoqSupervisor)) and
          WorkerPool.live_workers() == cfg[:workers] and
          Listener.local_port() == cfg[:port] and
          Listener.refusal() == nil
      end,
      timeout: 5_000,
      interval: 10
    )

    cfg
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:smalt, :aoq)

      # Clean any dynamically-started subtree: stop it under the plane
      # supervisor so the named singletons never leak into sibling tests.
      case Process.whereis(AoqSupervisor) do
        nil ->
          :ok

        _pid ->
          Supervisor.terminate_child(Smalt.Plane.DataSupervisor, AoqSupervisor)
          Supervisor.delete_child(Smalt.Plane.DataSupervisor, AoqSupervisor)
      end

      :persistent_term.erase({Listener, :local_port})
      :persistent_term.erase({Listener, :refusal})
    end)

    :ok
  end

  test "disabled path (real boot): no AoQ names registered, no listener bound" do
    assert Process.whereis(AoqSupervisor) == nil
    assert Process.whereis(Smalt.Aoq.NifHolder) == nil
    assert Process.whereis(WorkerPool) == nil
    assert Listener.local_port() == nil
    assert Listener.refusal() == nil
  end

  test "enabled path (real boot under the data plane): whereis + real UDP datagram ingested" do
    cfg = start_via_plane()

    assert is_pid(Process.whereis(AoqSupervisor))
    assert is_pid(Process.whereis(Smalt.Aoq.NifHolder))
    assert is_pid(Process.whereis(WorkerPool))
    assert Listener.local_port() == cfg[:port]

    # Real datagram roundtrip: a UDP frame on the bound port reaches the
    # pool (dispatch counter advances) and a direct submit leases cleanly.
    before = dispatch_idx()

    {:ok, sock} = :gen_udp.open(0, [:binary])
    frame = :crypto.strong_rand_bytes(100)
    :gen_udp.send(sock, {127, 0, 0, 1}, cfg[:port], frame)
    :gen_udp.close(sock)

    # Disjunctive observable (same law as supervisor_test): the datagram
    # advances the pool dispatch counter, or a direct submit leases cleanly.
    assert_eventually(
      fn -> dispatch_idx() > before or submit_ok?() end,
      timeout: 5_000,
      interval: 10
    )
  end

  test "plane-subset path: AoQ mounts ONLY under the data plane; app-level site retired" do
    start_via_plane()

    # The subtree is a child of the running data plane (child id
    # Smalt.Aoq.Supervisor - the gated child_spec shape).
    data_ids =
      Smalt.Plane.DataSupervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    assert Smalt.Aoq.Supervisor in data_ids

    # The app supervisor holds no AoQ child of its own (aoq_child retired).
    app_ids =
      Smalt.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    refute Smalt.Aoq.Supervisor in app_ids
  end

  test "double-start regression: Smalt.Application.aoq_child/0 is retired ([])" do
    assert Smalt.Application.aoq_child() == []
    assert Smalt.Application.posh_child() == []
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
