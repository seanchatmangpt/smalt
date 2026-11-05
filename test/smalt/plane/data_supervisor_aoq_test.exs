defmodule Smalt.Plane.DataSupervisorAoqTest do
  @moduledoc false
  # LANE-11 / C2: the AoQ subtree's single lawful start site is the data
  # plane (Smalt.Plane.DataSupervisor). Chicago discipline: real supervised
  # boot under the REAL running plane supervisor, real HTTP over the real
  # listener, real worker processes. No mocks, no Process.sleep — bounded
  # polls on real observables only.
  use ExUnit.Case, async: false

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  alias Smalt.Aoq.NifHolder
  alias Smalt.Aoq.Supervisor, as: AoqSupervisor
  alias Smalt.Aoq.WorkerPool

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  # mix test boots Smalt.Application before the suite, and config/test.exs
  # does NOT enable AoQ — the running tree IS the disabled path. The enabled
  # path therefore starts the real child through the real plane supervisor
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
        is_pid(Process.whereis(AoqSupervisor)) and WorkerPool.live_workers() == 3
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
    end)

    :ok
  end

  test "disabled path (real boot): no AoQ names registered, wire face refuses" do
    assert Process.whereis(AoqSupervisor) == nil
    assert Process.whereis(NifHolder) == nil
    assert Process.whereis(WorkerPool) == nil

    # Nothing binds the default 9093 anywhere in this plane (disabled here:
    # no listener, the connect is refused).
    result = :httpc.request(:http, {~c"http://127.0.0.1:9093/healthz", []}, [], [])
    assert {:error, _} = result
    assert inspect(result) =~ "econnrefused"
  end

  test "enabled path (real boot under the data plane): whereis + healthz roundtrip" do
    cfg = start_via_plane()

    assert is_pid(Process.whereis(AoqSupervisor))
    assert is_pid(Process.whereis(NifHolder))
    assert is_pid(Process.whereis(WorkerPool))

    {:ok, {{_v, 200, _r}, _h, "ok"}} =
      :httpc.request(:http, {~c"http://127.0.0.1:#{cfg[:port]}/healthz", []}, [], [])

    :ok
  end

  test "plane-subset path: AoQ mounts ONLY under the data plane; app-level site retired" do
    start_via_plane()

    # The subtree is a child of the running data plane (child id
    # Smalt.Aoq.Supervisor — the gated child_spec shape).
    data_ids =
      Smalt.Plane.DataSupervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    assert AoqSupervisor in data_ids

    # The app supervisor holds no AoQ child of its own (aoq_child retired).
    app_ids =
      Smalt.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    refute AoqSupervisor in app_ids
  end

  test "double-start regression: Smalt.Application.aoq_child/0 is retired ([])" do
    assert Smalt.Application.aoq_child() == []
    assert Smalt.Application.posh_child() == []
  end
end
