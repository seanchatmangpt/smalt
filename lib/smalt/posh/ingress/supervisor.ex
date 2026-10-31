defmodule Smalt.Posh.IngressSupervisor do
  @moduledoc """
  Ingress subtree (Port In). Owns admission-side processes only; shares no
  process with the egress subtree.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :ingress_name, __MODULE__))
  end

  @impl true
  def init(opts) do
    task_sup = Keyword.get(opts, :task_supervisor_name, Smalt.Posh.Ingress.TaskSupervisor)

    children = [
      {Task.Supervisor, name: task_sup},
      {Smalt.Posh.Ingress.RingBuffer,
       capacity: Keyword.get(opts, :capacity, 64),
       name: Keyword.get(opts, :ring_name, Smalt.Posh.Ingress.RingBuffer)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
