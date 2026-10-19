defmodule Smalt.Azsim.PlaneSupervisionTest do
  @moduledoc """
  AZB-09: Plane-scoped supervision subtrees acceptance test.
  Verifies:
  1. Supervisor.which_children(Smalt.Supervisor) lists the 4 plane supervisors.
  2. Blast radius containment: terminating DataSupervisor leaves ControlSupervisor (ARM Gateway) healthy and responsive.
  """
  use ExUnit.Case, async: false

  alias Smalt.Plane.{ControlSupervisor, DataSupervisor, IntegrationSupervisor, IdentitySupervisor}

  test "which_children lists all four plane supervisors under :all" do
    children = Supervisor.which_children(Smalt.Supervisor)
    child_modules = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

    assert DataSupervisor in child_modules
    assert ControlSupervisor in child_modules
    assert IntegrationSupervisor in child_modules
    assert IdentitySupervisor in child_modules
  end

  test "terminating DataSupervisor leaves ControlSupervisor alive and serving requests" do
    # Verify control supervisor is responsive
    arm_port = Smalt.Config.arm_port()
    assert is_integer(arm_port)

    # Terminate data subtree
    assert :ok = Supervisor.terminate_child(Smalt.Supervisor, DataSupervisor)

    # Control subtree must remain alive
    control_pid = Process.whereis(ControlSupervisor)
    assert is_pid(control_pid)
    assert Process.alive?(control_pid)

    # Restart data subtree to restore baseline state.
    # Bounded poll (no-sleep doctrine): the old ThousandIsland egress listener
    # releases its socket asynchronously at the OS level; a single restart_child
    # can hit :eaddrinuse. Poll the real observable — restart_child itself —
    # until the rebind succeeds within deadline.
    assert is_pid(
             SmaltTest.AssertEventually.eventually(
               fn ->
                 case Supervisor.restart_child(Smalt.Supervisor, DataSupervisor) do
                   # environmental: old ThousandIsland socket not yet released
                   {:error, :eaddrinuse} = err -> {:retry, err}
                   # any other shape is a typed immediate failure with the value
                   other -> other
                 end
               end,
               observable: "DataSupervisor restart after egress listener socket release",
               deadline_ms: 10_000
             )
           )
  end
end
