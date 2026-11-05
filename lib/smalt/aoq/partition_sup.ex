defmodule Smalt.Aoq.PartitionSup do
  @moduledoc """
  DynamicSupervisor over partition workers, one_for_one, children keyed
  by `ring_id` (LANE-05). Rings are minted at runtime via
  `Smalt.Aoq.Partitions.ensure_ring/2`; a killed worker restarts
  :permanent and adopts the same off-heap cursor from the registry, so
  the per-ring seq continues across crashes.
  """

  use DynamicSupervisor

  @doc "Starts the dynamic partition supervisor."
  def start_link(cfg) do
    DynamicSupervisor.start_link(__MODULE__, cfg, name: __MODULE__)
  end

  @impl true
  def init(_cfg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
