defmodule Smalt.Posh.EgressSupervisor do
  @moduledoc """
  Egress subtree (Starboard Out). Owns settlement-side processes only; shares
  no process with the ingress subtree.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :egress_name, __MODULE__))
  end

  @impl true
  def init(opts) do
    children =
      case Keyword.get(opts, :dir) do
        nil -> []
        dir -> [{Smalt.Posh.Egress.EventLog, dir: dir, name: Keyword.get(opts, :log_name, Smalt.Posh.Egress.EventLog)}]
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
