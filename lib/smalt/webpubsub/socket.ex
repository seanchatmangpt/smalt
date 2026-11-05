defmodule Smalt.WebPubSub.Socket do
  @moduledoc """
  Client WebSocket for the Web PubSub face (AZ-5), subprotocol
  `json.webpubsub.azure.v1` (cite
  https://learn.microsoft.com/azure/azure-web-pubsub/websocket-client-protocol:
  client frames are JSON text frames
  {"type":"joinGroup"|"leaveGroup"|"sendToGroup"|"event"} with optional
  `ackId`; the service answers {"type":"ack","ackId":N,"success":bool,
  "error":{name,message}} for acked messages and
  {"type":"error","message":...} otherwise; group messages arrive as
  {"type":"message","from":"group","group":g,"dataType":"binary"} where
  binary dataType rides BINARY frames -- raw bytes, byte-exact on the
  emulator (base64-in-JSON variant noted in the receipt as a
  divergence-class note).

  `# KD-COVERS: KD-166` -- Bandit 1.6 has no Sec-WebSocket-Protocol
  negotiation, so the 101 does not echo the subprotocol; clients that
  require the echo break on the emulator (registered KD-166).

  `# KD-COVERS: KD-178` -- the socket monitors the broker
  (Smalt.WebPubSub) and closes on broker death, reproducing real Azure's
  client-disconnect-on-restart semantics (reconnect+rejoin cycle) instead
  of sockets silently riding the separately-supervised Bandit listener
  with a wiped group registry.
  """

  @behaviour WebSock


  defstruct [:hub, :user_id, :roles, :conn_id, groups: [], broker_ref: nil]

  # -- WebSock callbacks --------------------------------------------------------

  @impl true
  def init(%{hub: hub, user_id: user_id, roles: roles, conn_id: conn_id}) do
    :ok = Smalt.WebPubSub.Events.connected(hub, conn_id, user_id)

    # KD-178: link socket lifetime to broker death. The broker
    # (Smalt.WebPubSub) and the Bandit HTTP listener are separately
    # supervised one_for_one children, so a supervised broker crash
    # restarts the broker while connected client sockets keep riding the
    # live listener with a wiped group registry — publish honestly answers
    # {:ok, 0} over dead membership with no client-visible signal. Real
    # Azure drops the client WebSocket on a broker restart (forcing the
    # reconnect+rejoin cycle). Monitor the broker from the socket so the
    # socket closes when the broker dies: the client sees the disconnect
    # and rejoins on the restarted broker, exactly the real-service cycle.
    broker_ref =
      case Process.whereis(Smalt.WebPubSub) do
        nil -> nil
        broker_pid -> Process.monitor(broker_pid)
      end

    {:ok, %__MODULE__{hub: hub, user_id: user_id, roles: roles, conn_id: conn_id, broker_ref: broker_ref}}
  end

  @impl true
  def handle_in({data, opcode: :text}, state) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"type" => t} = msg} when t in ["joinGroup", "leaveGroup", "sendToGroup", "event"] ->
        dispatch(t, msg, state)

      _ ->
        error_frame(state, "malformed message: expected json.webpubsub.azure.v1 envelope")
    end
  end

  @impl true
  def handle_in({_data, opcode: :binary}, state) do
    error_frame(state, "binary client frames are not subprotocol messages")
  end

  @impl true
  def handle_info({:wps_push, data}, state) do
    {:push, {:binary, data}, state}
  end

  # KD-178: the monitored broker died — close the connection (real-Azure
  # disconnect semantics) so the client reconnects and rejoins against the
  # restarted broker instead of riding the listener with dead membership.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{broker_ref: ref} = state) do
    {:stop, {:shutdown, :broker_restarted}, state}
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{hub: hub, conn_id: cid, user_id: uid, groups: groups}) do
    # EXPL-11 F3: a socket's groups must not outlive the socket — the
    # broker prunes dead pids anyway, but an explicit leave keeps the
    # registry truthful at the moment of death. KD-178: the broker may be
    # mid-restart when a broker-linked socket dies; a GenServer.call to a
    # dead name is an :noproc exit, so only leave when the broker is live.
    if Process.whereis(Smalt.WebPubSub) do
      Enum.each(groups, fn g -> Smalt.WebPubSub.leave(hub, g, self()) end)
    end

    :ok = Smalt.WebPubSub.Events.disconnected(hub, cid, uid)
    :ok
  end

  # -- Message dispatch ---------------------------------------------------------

  defp dispatch("joinGroup", %{"group" => g} = msg, state) do
    if permitted?(state.roles, "webpubsub.joinLeaveGroup", g) do
      :ok = Smalt.WebPubSub.join(state.hub, g, self())
      acked(msg, %{state | groups: if(g in state.groups, do: state.groups, else: [g | state.groups])}, ack_ok(msg["ackId"]))
    else
      acked(msg, state, ack_err(msg["ackId"], "Forbidden", "join #{g}"))
    end
  end

  defp dispatch("leaveGroup", %{"group" => g} = msg, state) do
    # EXPL-4 F6: permission-checked symmetric to joinGroup — the real
    # service's joinLeaveGroup role gates both faces; the previously
    # unregistered leave asymmetry is closed.
    if permitted?(state.roles, "webpubsub.joinLeaveGroup", g) do
      :ok = Smalt.WebPubSub.leave(state.hub, g, self())
      acked(msg, %{state | groups: List.delete(state.groups, g)}, ack_ok(msg["ackId"]))
    else
      acked(msg, state, ack_err(msg["ackId"], "Forbidden", "leave #{g}"))
    end
  end

  defp dispatch("event", %{"event" => evt} = msg, state) do
    :ok =
      Smalt.WebPubSub.Events.emit_custom(
        state.hub,
        state.conn_id,
        state.user_id,
        evt,
        msg["data"]
      )

    acked(msg, state, ack_ok(msg["ackId"]))
  end

  defp dispatch("sendToGroup", %{"group" => g, "data" => data} = msg, state) do
    if permitted?(state.roles, "webpubsub.sendToGroup", g) do
      payload = to_binary(data, msg["dataType"])
      {:ok, _n} = Smalt.WebPubSub.publish(state.hub, g, payload)
      acked(msg, state, ack_ok(msg["ackId"]))
    else
      acked(msg, state, ack_err(msg["ackId"], "Forbidden", "send to #{g}"))
    end
  end

  # EXPL-4 F6: catch-all — a known type with a missing key (sendToGroup
  # without "group"/"data", event without "event", ...) answers the
  # protocol error frame, never a FunctionClauseError kill.
  defp dispatch(t, msg, state) do
    acked(msg, state, ack_err(msg["ackId"], "InvalidMessage", "#{t}: missing required key"))
  end

  # -- Frame helpers ------------------------------------------------------------

  # Real service: an ackId'd message gets an ack frame; an unacked denied
  # message gets an error frame. success=false acks carry
  # error {name, message} (e.g. name "Forbidden").
  defp acked(_msg, state, nil), do: {:ok, state}
  defp acked(_msg, state, frame), do: {:push, {:text, frame}, state}

  defp ack_ok(nil), do: nil

  defp ack_ok(ack_id) do
    Jason.encode!(%{"type" => "ack", "ackId" => ack_id, "success" => true})
  end

  defp ack_err(nil, name, message), do: error_frame_now(name, message)

  defp ack_err(ack_id, name, message) do
    Jason.encode!(%{
      "type" => "ack",
      "ackId" => ack_id,
      "success" => false,
      "error" => %{"name" => name, "message" => message}
    })
  end

  defp error_frame(state, message) do
    {:push, {:text, Jason.encode!(%{"type" => "error", "message" => message})}, state}
  end

  defp error_frame_now(name, message) do
    Jason.encode!(%{"type" => "error", "message" => "#{name}: #{message}"})
  end

  # Real role grammar: `webpubsub.joinLeaveGroup` (all groups) or
  # `webpubsub.joinLeaveGroup.<group>` (single group).
  defp permitted?(roles, prefix, group) do
    Enum.any?(roles, fn r -> r == prefix or r == prefix <> "." <> group end)
  end

  defp to_binary(data, _dt) when is_binary(data), do: data
  defp to_binary(data, _dt), do: Jason.encode!(data)
end
