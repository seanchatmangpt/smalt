defmodule Smalt.Plane.Identity.StsGate do
  @moduledoc """
  AZB-15 identity-plane STS mint gate.

  The identity plane's DR contract (ticket AZB-15, binding): killing the
  identity subtree must make NEW token mints fail with a typed 503 while
  cached-valid tokens keep being accepted by the data/control seats (bearer
  validation is local — shared-secret Joken verification, no runtime call
  into the identity plane).

  The gate process itself carries no state; it exists so the identity subtree
  owns a real, killable child whose liveness the mint path can consult. The
  `:persistent_term` boot marker is written once at gate start and survives
  the kill, so the mint path distinguishes:

    - identity plane never booted in this VM (split profile without
      `:identity`, ExUnit-owned wire trees) → mint stays open (back-compat
      with control-only boots — the STS surface is hosted by the ARM gateway);
    - identity plane booted then its subtree was killed → `mint_allowed?/0`
      is false ⇒ the router answers a typed 503 `StsUnavailable`.
  """

  use GenServer

  @boot_marker {__MODULE__, :booted}

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  False only when the identity plane booted in this VM and its subtree is
  currently dead (DR kill). Open otherwise.
  """
  def mint_allowed? do
    case :persistent_term.get(@boot_marker, false) do
      false -> true
      true -> Process.whereis(__MODULE__) != nil
    end
  end

  @doc "Test seam: forget the boot marker (scenario isolation across suites)."
  def forget_boot_marker, do: :persistent_term.erase(@boot_marker)

  @impl true
  def init(:ok) do
    :persistent_term.put(@boot_marker, true)
    {:ok, %{}}
  end
end
