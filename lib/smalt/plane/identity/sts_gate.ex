defmodule Smalt.Plane.Identity.StsGate do
  @moduledoc """
  AZB-15 identity-plane STS mint gate.

  The identity plane's DR contract (ticket AZB-15, binding): killing the
  identity subtree must make NEW token mints fail with a typed 503 while
  cached-valid tokens keep being accepted by data/control seats (bearer
  validation is local - shared-secret Joken verification, no runtime call
  into the identity plane).

  The gate process carries no state; it exists so the identity subtree owns a
  real, killable child. `mint_allowed?/0` reads LIVE supervision state, not a
  boot marker (a marker set by any all-planes boot would leak into ExUnit
  wire trees that intentionally run without the identity plane - witnessed:
  arm_wire_test mint -> 503):

    - `Smalt.Supervisor` not running (app stopped; ExUnit wire trees) -> open;
    - identity subtree configured AND its pid not alive (DR kill window) ->
      closed => the ARM router answers typed 503 `StsUnavailable`;
    - otherwise (split profile without `:identity`, subtree serving) -> open.
  """

  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  False only when the identity subtree is a configured child of the live app
  supervisor and its process is not currently serving (DR kill window).
  Open otherwise.
  """
  def mint_allowed? do
    sup = Process.whereis(Smalt.Supervisor)

    if is_nil(sup) do
      true
    else
      case List.keyfind(Supervisor.which_children(sup), Smalt.Plane.IdentitySupervisor, 0) do
        {_id, pid, _type, _mods} when is_pid(pid) -> Process.alive?(pid)
        # Child entry present but no live pid: terminated/restarting — this
        # IS the DR kill window.
        {_, :undefined, _, _} -> false
        # Not a configured child: split boot or app stopped - never a kill.
        nil -> true
      end
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{}}
end
