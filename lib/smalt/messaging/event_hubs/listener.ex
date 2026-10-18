defmodule Smalt.Messaging.EventHubs.Listener do
  @moduledoc """
  Event Hubs lane listener (port `Application.get_env(:smalt, :event_hubs_port, 5673)`).

  A thin wrapper that runs `Smalt.Amqp.Listener` in `:eh` mode: same AMQP stack,
  same `Smalt.Amqp.Connection`, mode flag `:eh`, connections under
  `Smalt.AmqpBroker.ConnSup`. Exists as its own module so the broker supervisor's
  two listener children have distinct child ids and registered names.
  """

  @doc "Child spec for `{Smalt.Messaging.EventHubs.Listener, {:eh, port}}` (bare port also accepted)."
  def child_spec(port) when is_integer(port) do
    child_spec({:eh, port})
  end

  def child_spec({:eh, port}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [{:eh, port}]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Starts the EH listener. Accepts `{:eh, port}`."
  def start_link({:eh, port}) do
    Smalt.Amqp.Listener.start_link(
      {:eh, port,
       name: Module.concat(Smalt.Amqp.Listener, :Eh), conn_sup: Smalt.AmqpBroker.conn_sup_name()}
    )
  end
end
