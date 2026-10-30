# WO-32 control-plane boot court (v26.10.31 cordon/cutover).
#
# Post-cordon expectations, against the REAL booted app tree (mix test
# self-boots :smalt; no mocks — Chicago). The isolated control-only boot leg
# (terminate ControlSupervisor + restart under planes=[:control]) is NOT
# exercised here: the control-only store_child prepends Smalt.Store, a named
# singleton already running under DataSupervisor in the test boot, so a
# [:control] restart would double-start Store and fail the tree. Real
# observables instead: live child-id inspection, a real :gen_tcp connect
# probe on the arm port, real Smalt.Planes.resolve/0 under
# SMALT_PLANES=control.
defmodule Internal.WO32.ControlBootCourtTest do
  use ExUnit.Case, async: false

  @sup Smalt.Plane.ControlSupervisor

  setup do
    prior = System.get_env("SMALT_PLANES")

    on_exit(fn ->
      if prior do
        System.put_env("SMALT_PLANES", prior)
      else
        System.delete_env("SMALT_PLANES")
      end
    end)

    :ok
  end

  # Ruling (wave-1 L3, honored by WO-32): the LRO record state machine is
  # vendor-neutral core and its Sweeper/Notifier single-writers STAY. Only
  # the ARM ROUTER LISTENER leaves — so the cordon assert refuses Router/
  # Bandit children, NOT the literal module prefix ArmGateway (which the
  # two LRO single-writer ids legitimately carry).
  test "control plane holds zero ArmGateway ROUTER/LISTENER children" do
    ids = child_ids()

    refute Enum.any?(ids, fn id -> inspect(id) =~ "Bandit" end),
           "listener children survived the cordon: #{inspect(ids)}"

    assert Smalt.ArmGateway.LRO.Sweeper in ids,
           "LRO Sweeper (core state-machine single-writer) missing: #{inspect(ids)}"

    assert Smalt.ArmGateway.LRO.Notifier in ids,
           "LRO Notifier (core state-machine single-writer) missing: #{inspect(ids)}"

    refute Enum.any?(ids, fn id -> inspect(id) =~ "Router" end),
           "ARM router child survived the cordon: #{inspect(ids)}"
  end

  test "standards admission engine is a control-plane child" do
    ids = child_ids()

    assert Enum.any?(ids, fn id -> inspect(id) =~ "PoshEngine" end),
           "Posh admission engine child missing from control plane: #{inspect(ids)}"
  end

  test "BEAM no longer binds the arm port — connect refused" do
    port = Smalt.Config.arm_port()

    assert match?({:error, :econnrefused}, :gen_tcp.connect('127.0.0.1', port, [], 250)) or
             match?({:error, :econnaborted}, :gen_tcp.connect('127.0.0.1', port, [], 250)),
           "something is still accepting on the arm port #{port}"
  end

  test "SMALT_PLANES=control resolves to [:control]" do
    System.put_env("SMALT_PLANES", "control")

    assert Smalt.Planes.resolve() == [:control]
  end

  defp child_ids do
    @sup
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 0))
  end
end
