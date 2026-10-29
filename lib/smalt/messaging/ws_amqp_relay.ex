defmodule Smalt.Messaging.WsAmqpRelay do
  @moduledoc """
  Domain-blind WebSocket -> AMQP relay (BK-58, BK-40 lane 3 deliverable).

  The in-browser BEAM cannot open raw TCP sockets for SASL AMQP
  (`:eprotonosupport` class). Real-Azure SB/EH precedent is
  AMQP-over-WebSocket. This relay is the host-side bridge: a loopback WS
  face whose socket process owns the raw TCP AMQP connection to the sb/eh
  listeners and shuffles OPAQUE BYTES bidirectionally -- no AMQP framing
  interpretation beyond WS/TCP framing itself.

  Law status: the workspace networking law (`workspace/lib/smalt.ts` +
  `workspace/eslint.config.mjs`) bans `ws*` imports and raw-fetch literals
  and routes ALL networking through `smaltFetch`/`assertLocalUrl`; `fetch()`
  cannot do WebSockets. The ESLint config does not currently ban the
  browser-native `WebSocket` global, but the documented law is
  smaltFetch-only -- under the law as written the browser eg/topic/eh leg is
  TYPED-PERMANENT (transport law, not a missing feature); the relay is a
  HOST-side bridge only. Extending the workspace law to admit a
  loopback-native WebSocket global would be a harness self-edit requiring
  an out-of-family falsifier (C22) -- not done here.

  Surface:
  - `GET /ws/amqp/sb` -> upstream `Smalt.Amqp.Listener.Sb` (5672 lane)
  - `GET /ws/amqp/eh` -> upstream `Smalt.Amqp.Listener.Eh` (5673 lane)
  - `GET /$servicebus/*` -> Service Bus lane (the Azure-SDK AMQP-over-WS
    path, routed through `Smalt.Messaging.AmqpWsBridge.lane_for_path/1`)
  - anything else -> 404 typed refusal.

  Degrades honestly: if the lane listener is not running, the WS open is
  refused with a typed close (1011, description names the lane), never a
  fake open. Bytes are never inspected, buffered beyond WS/TCP framing, or
  transformed.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/ws/amqp/:lane" do
    lane_upgrade(lane, conn)
  end

  # WS-AMQP: the path real Azure SDKs build for AMQP-over-WebSocket
  # (wss://<ns>/$servicebus/websockets). Routed to the sb lane.
  get "/$servicebus/*_" do
    lane_upgrade("sb", conn)
  end

  match _ do
    send_resp(conn, 404, "not found: AMQP relay paths are /ws/amqp/sb and /ws/amqp/eh\n")
  end

  defp lane_upgrade("sb", conn), do: do_upgrade(conn, :sb)
  defp lane_upgrade("eh", conn), do: do_upgrade(conn, :eh)

  defp lane_upgrade(_other, conn) do
    send_resp(conn, 404, "unknown lane: use sb or eh\n")
  end

  defp do_upgrade(conn, lane) do
    case echo_subprotocol(conn) do
      :refuse ->
        send_resp(
          conn,
          400,
          "unsupported subprotocol: this relay speaks only amqp\n"
        )

      conn ->
        Plug.Conn.upgrade_adapter(conn, :websocket, {
      Smalt.Messaging.WsAmqpRelay.Socket,
      %{lane: lane},
      []
    })
    end
  end

  # CANDIDATE C: negotiated echo with typed refusal. First supported subprotocol
  # ("amqp") is echoed; a client that offers protocols but none supported gets a
  # typed 400 refusal — never a fake open (relay degrade-honestly law).
  # KD-WS-SDK: both wire tokens witnessed live — "amqp" (EH/AMQP-over-WS
  # convention) and "AMQPWSB10" (the real @azure/service-bus offer).
  @supported_subprotocols ["amqp", "AMQPWSB10"]

  defp echo_subprotocol(conn) do
    offered =
      conn
      |> Plug.Conn.get_req_header("sec-websocket-protocol")
      |> Enum.flat_map(&Plug.Conn.Utils.list/1)
      |> Enum.map(&String.trim/1)

    cond do
      offered == [] ->
        conn

      Enum.any?(offered, &(&1 in @supported_subprotocols)) ->
        pick = Enum.find(offered, &(&1 in @supported_subprotocols))
        Plug.Conn.put_resp_header(conn, "sec-websocket-protocol", pick)

      true ->
        :refuse
    end
  end
end

defmodule Smalt.Messaging.WsAmqpRelay.Socket do
  @moduledoc """
  One relay leg: owns the upstream raw TCP socket to the lane's AMQP
  listener for the lifetime of the WebSocket connection. Bytes are opaque
  in both directions.

  Runs inside the Bandit connection process; upstream TCP data arrives as
  `handle_info({:tcp, ...})` because `init/1` runs in that process and the
  socket is opened `active: true`.
  """

  @behaviour WebSock

  @connect_timeout_ms 5_000

  @impl true
  def init(%{lane: lane}) do
    case upstream_port(lane) do
      {:ok, port} ->
        conn_opts = [:binary, active: true, nodelay: true]

        case :gen_tcp.connect(~c"127.0.0.1", port, conn_opts, @connect_timeout_ms) do
          {:ok, sock} ->
            {:ok, %{sock: sock}}

          {:error, reason} ->
            {:stop, {:shutdown, :upstream_refused},
             {1011, "upstream connect failed: " <> inspect(reason)}}
        end

      :down ->
        {:stop, {:shutdown, :upstream_down},
         {1011, "amqp listener not running for lane " <> Atom.to_string(lane)}}
    end
  end

  @impl true
  def handle_in({data, opcode: :binary}, state) when is_binary(data) do
    upstream_send(data, state)
  end

  def handle_in({data, opcode: :text}, state) when is_binary(data) do
    upstream_send(data, state)
  end

  defp upstream_send(data, %{sock: sock} = state) do
    case :gen_tcp.send(sock, data) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        {:stop, {:shutdown, :upstream_error},
         {1011, "upstream send failed: " <> inspect(reason)}, state}
    end
  end

  @impl true
  def handle_info({:tcp, _sock, data}, state) do
    {:push, {:binary, data}, state}
  end

  def handle_info({:tcp_closed, _sock}, state) do
    {:stop, :normal, {1001, "upstream closed"}, state}
  end

  def handle_info({:tcp_error, _sock, reason}, state) do
    {:stop, {:shutdown, :upstream_error}, {1011, "upstream error: " <> inspect(reason)}, state}
  end

  @impl true
  def terminate(_reason, %{sock: sock}) when sock != nil do
    :gen_tcp.close(sock)
  end

  def terminate(_reason, _state), do: :ok

  # -- Upstream resolution ------------------------------------------------------

  defp upstream_port(:sb), do: listener_port(Module.concat(Smalt.Amqp.Listener, :Sb))
  defp upstream_port(:eh), do: listener_port(Module.concat(Smalt.Amqp.Listener, :Eh))

  defp listener_port(name) do
    case Process.whereis(name) do
      nil -> :down
      pid -> {:ok, Smalt.Amqp.Listener.port(pid)}
    end
  end
end
