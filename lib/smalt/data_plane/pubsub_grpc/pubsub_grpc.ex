defmodule Smalt.PubSubGrpc do
  @moduledoc """
  Pub/Sub gRPC face facade (lane K-GC, v26.11.6) — RedisWire containment
  topology: the facade OWNS the bind. If the Bandit listener cannot bind,
  the child is simply not added to the tree and the app boots (the facade
  stays up serving nothing; AmqpBroker containment contract).

  ## Coordinator wiring (disclosed; application.ex is not lane-owned)

      # in Smalt.Application / Smalt.Plane.DataSupervisor children:
      Supervisor.child_spec({Smalt.PubSubGrpc, []}, shutdown: 10_000)

  Port: `config :smalt, :pubsub_grpc_port` (default 9297). TLS:
  `config :smalt, :pubsub_grpc_tls` (default false = cleartext h2c prior
  knowledge, which is what an insecure grpcio channel speaks); when true,
  cert material rides `Smalt.TLS.bandit_opts/2`.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc "Bound port of the live listener, or nil when the bind failed/skipped."
  def port, do: Application.get_env(:smalt, :pubsub_grpc_port, 9297)

  @impl true
  def init(_init_arg) do
    children =
      [
        Smalt.PubSubGrpc.Engine
      ] ++ bandit_child()

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 5)
  end

  # Containment contract: a bind failure stops the LISTENER, not the app.
  # Bandit is linked to this supervisor process (bind-in-init, the
  # RedisWire/AmqpBroker pattern): on facade death the listener dies with
  # it; on bind failure the child is simply not part of the tree.
  defp bandit_child do
    case Bandit.start_link(listener_opts()) do
      {:ok, _pid} ->
        []

      {:error, reason} ->
        require Logger

        Logger.warning(
          "[pubsub-grpc] listener could not bind port #{port()}: #{inspect(reason)}; " <>
            "booting without it"
        )

        []
    end
  end

  defp listener_opts do
    base = [plug: Smalt.PubSubGrpc.Plug, port: port()]

    if Application.get_env(:smalt, :pubsub_grpc_tls, false) do
      Smalt.TLS.bandit_opts(Smalt.PubSubGrpc.Plug, port())
    else
      base
    end
  end
end
