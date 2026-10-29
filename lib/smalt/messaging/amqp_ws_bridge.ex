defmodule Smalt.Messaging.AmqpWsBridge do
  @moduledoc """
  AMQP-over-WebSocket bridge: configuration + lane-routing face for the
  WS->AMQP byte tunnel (`Smalt.Messaging.WsAmqpRelay`, BK-58).

  Real Azure SB/EH SDKs (@azure/service-bus, @azure/event-hubs) speak AMQP
  1.0 tunneled through an RFC6455 binary WebSocket when the connection
  string carries `Transport=AmqpWebSockets`, or via `webSocketOptions`.
  The tunnel is transport-only: after the RFC6455 upgrade the socket becomes
  an opaque byte pipe to the SAME `Smalt.Amqp.Connection` state machine the
  TCP listeners (5672/5673) serve, so SASL-ANONYMOUS -> CBS put-token ->
  open/begin/attach/transfer negotiation is byte-identical to TCP.

  ## Ports and env

  Port resolution: `SMALT_AMQP_WS_PORT` env var, then app env
  `:ws_amqp_relay_port`, then 5675. (The lease suggested default 5674; 5675
  is kept because it is the witnessed BK-58 default already pinned in
  `config/test.exs` and the existing receipts. Env configurability is the
  load-bearing half; the default is unchanged drift control.)

  ## Lane routing

  - `/ws/amqp/sb` -> Service Bus lane (upstream `Smalt.Amqp.Listener.Sb`)
  - `/ws/amqp/eh` -> Event Hubs lane (upstream `Smalt.Amqp.Listener.Eh`)
  - `/$servicebus/*` -> Service Bus lane (the path real Azure SDKs build for
    AMQP-over-WS: `wss://<ns>.servicebus.windows.net/$servicebus/websockets`)
  - anything else -> typed 404 refusal, never an upgrade.

  ## Coordinator SDK connection-string shape

  With the bridge on `ws://127.0.0.1:<port>`:

      Endpoint=sb://127.0.0.1:<port>/;SharedAccessKeyName=...;SharedAccessKey=...;
      Transport=AmqpWebSockets

  In @azure/service-bus / @azure/event-hubs (rhea over `webSocketOptions`),
  point the WS leg at the local bridge with
  `webSocketOptions.customEndpointAddress = "ws://127.0.0.1:<port>"` — the
  SDK keeps its own `/$servicebus/websockets` path (served here as the sb
  lane), Host header, and SASL/CBS behavior. Path `/ws/amqp/<lane>` remains
  the explicit host-side lane selector.
  """

  @default_port 5675

  @doc """
  Resolved bridge port: `SMALT_AMQP_WS_PORT` env var, then app env
  `:ws_amqp_relay_port`, then 5675. A non-integer env value refuses with
  `ArgumentError` (fail-closed).
  """
  @spec port() :: :inet.port_number()
  def port do
    case System.get_env("SMALT_AMQP_WS_PORT") do
      nil ->
        Application.get_env(:smalt, :ws_amqp_relay_port, @default_port)

      raw ->
        case Integer.parse(raw) do
          {int, ""} when int > 0 -> int
          {int, _rest} when int > 0 -> int
          _ ->
            raise ArgumentError,
                  "SMALT_AMQP_WS_PORT must be an integer port, got: #{inspect(raw)}"
        end
    end
  end

  @doc """
  Lane for a WS upgrade request path. `{:ok, :sb | :eh}` for served paths,
  `:error` for anything else (typed refusal upstream).
  """
  @spec lane_for_path(String.t()) :: {:ok, :sb | :eh} | :error
  def lane_for_path(path) when is_binary(path) do
    [path_no_query | _] = String.split(path, "?", parts: 2)
    lane_for_path_no_query(path_no_query)
  end

  defp lane_for_path_no_query("/ws/amqp/sb"), do: {:ok, :sb}
  defp lane_for_path_no_query("/ws/amqp/eh"), do: {:ok, :eh}

  defp lane_for_path_no_query("/" <> rest) do
    if String.starts_with?(rest, "$servicebus") do
      {:ok, :sb}
    else
      :error
    end
  end

  defp lane_for_path_no_query(_), do: :error
end
