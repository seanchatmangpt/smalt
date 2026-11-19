defmodule Smalt.Aoq.QuicSession.Supervisor do
  @moduledoc """
  DynamicSupervisor for `Smalt.Aoq.QuicSession.Session` processes
  (FNOX-SJ-QUIC-2). Sessions are `:temporary`; one crash never restarts or
  disturbs a sibling.

  `handler/1` returns a `Smalt.Aoq.Quic.Listener` `:handler` function that
  binds each accepted connection to a fresh session under the given supervisor.
  """

  use DynamicSupervisor

  alias Smalt.Aoq.QuicSession.Session

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Starts a session owning `conn` under `sup`."
  @spec start_session(Supervisor.supervisor(), reference(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_session(sup, conn, opts \\ []) do
    DynamicSupervisor.start_child(sup, {Session, Keyword.put(opts, :conn, conn)})
  end

  @doc "Listener handler: one session per accepted connection."
  @spec handler(Supervisor.supervisor(), keyword()) :: (reference() -> any())
  def handler(sup, opts \\ []), do: fn conn -> start_session(sup, conn, opts) end

  @doc "Live session pids under `sup`."
  @spec sessions(Supervisor.supervisor()) :: [pid()]
  def sessions(sup) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid), do: pid
  end
end
