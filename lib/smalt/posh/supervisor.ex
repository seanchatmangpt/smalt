defmodule Smalt.Posh.Supervisor do
  @moduledoc """
  POSH engine supervision tree (POSH-002 BEAM side).

  One-for-one tree isolating the Ingress subtree (Port In: admission + bounded
  ring buffer) from the Egress subtree (Starboard Out: settlement + append-only
  event log). The subtrees share no processes: ingress state lives only under
  `Smalt.Posh.Ingress`, egress state only under `Smalt.Posh.Egress`.
  """

  use Supervisor

  @doc """
  Starts the POSH supervisor. Options are forwarded to the ingress ring buffer
  and the egress event log:

      start_link(dir: "/path/to/events", capacity: 64)

  `:dir` is required for the event log to start; when omitted the egress
  subtree starts in a degraded, memory-only mode (no file persistence) so the
  tree can boot standalone in tests that don't exercise the log.
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name, __MODULE__)},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @impl true
  def init(opts) do
    children =
      port_child(opts) ++
      [
        {Smalt.Posh.IngressSupervisor, opts},
        {Smalt.Posh.EgressSupervisor, opts}
      ] ++ client_child(opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp port_child(opts) do
    with {:ok, bin_path} <- Keyword.fetch(opts, :bin_path),
         {:ok, socket_path} <- Keyword.fetch(opts, :socket_path) do
      port_opts = [bin_path: bin_path, socket_path: socket_path] ++ Keyword.take(opts, [:boot_timeout_ms])
      [Supervisor.child_spec({Smalt.Posh.Port, port_opts}, restart: :transient)]
    else
      _ -> []
    end
  end

  # The membrane client joins the tree only when a socket path is given:
  # :transient restart keeps a cleanly-stopped client down while still
  # restarting one that crashed, and a missing :socket_path means the caller
  # manages the client lifecycle itself (tests, standalone boots).
  defp client_child(opts) do
    case Keyword.fetch(opts, :socket_path) do
      {:ok, path} -> [Supervisor.child_spec({Smalt.Posh.Client, socket_path: path}, restart: :transient)]
      :error -> []
    end
  end
end
