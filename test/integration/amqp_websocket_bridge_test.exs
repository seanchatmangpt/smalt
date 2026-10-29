# WS-AMQP lane: AMQP-over-WebSocket bridge integration court.
#
# Chicago discipline: real RFC6455 test client over real TCP against the
# real Bandit bridge (Smalt.Messaging.WsAmqpRelay), real bytes in BOTH
# directions, SASL-ANONYMOUS negotiation witnessed on the wire, and a full
# AMQP header->open exchange on the Azure-SDK path alias. No mocks.
#
# Falsifier carried forward for the coordinator (SDK-level court, outside
# this lane's in-process reach): post-restart, an athena-side
# @azure/service-bus client with
# `webSocketOptions: { customEndpointAddress: "ws://127.0.0.1:<port>" }`
# and connection string
# `Endpoint=sb://127.0.0.1:<port>/;...;Transport=AmqpWebSockets` must
# complete open/begin/attach/transfer over `/$servicebus/websockets`
# (sb lane) exactly as it does over TCP 5672.

defmodule Smalt.Integration.AmqpWebsocketBridgeTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp10.FrameDecoder
  alias Smalt.Amqp.FrameCodec
  alias SmaltTest.WsClient

  @amqp_header <<0x41, 0x4D, 0x51, 0x50, 0x00, 1, 0, 0>>
  @sasl_header <<0x41, 0x4D, 0x51, 0x50, 0x03, 1, 0, 0>>
  @recv_timeout 10_000

  # -- pure face -----------------------------------------------------------------

  test "port resolution: SMALT_AMQP_WS_PORT env wins over app env/default" do
    System.put_env("SMALT_AMQP_WS_PORT", "19999")
    assert Smalt.Messaging.AmqpWsBridge.port() == 19_999

    System.put_env("SMALT_AMQP_WS_PORT", "not-a-port")
    assert_raise ArgumentError, ~r/SMALT_AMQP_WS_PORT/, fn ->
      Smalt.Messaging.AmqpWsBridge.port()
    end

    System.delete_env("SMALT_AMQP_WS_PORT")
  end

  test "lane_for_path/1 routes the Azure-SDK path and typed-refuses others" do
    assert {:ok, :sb} = Smalt.Messaging.AmqpWsBridge.lane_for_path("/$servicebus/websockets")
    assert {:ok, :sb} = Smalt.Messaging.AmqpWsBridge.lane_for_path("/ws/amqp/sb")
    assert {:ok, :eh} = Smalt.Messaging.AmqpWsBridge.lane_for_path("/ws/amqp/eh")
    assert :error = Smalt.Messaging.AmqpWsBridge.lane_for_path("/nope")
  end

  # -- wire court ----------------------------------------------------------------

  test "sb lane over WS: SASL header echo, mechanisms, ANONYMOUS init, outcome 0" do
    port = Application.fetch_env!(:smalt, :ws_amqp_relay_port)
    ws = WsClient.connect(port, "/ws/amqp/sb")

    :ok = WsClient.send_binary(ws, @sasl_header)
    assert {:ok, echo, ws} = WsClient.recv_data(ws, @recv_timeout)
    assert echo == @sasl_header, "relay must echo the SASL header verbatim"

    assert {[%{type: :sasl, performative: {:sasl_mechanisms, _}}], ws, buf} =
             recv_amqp(ws, 1)

    # sasl-init with mechanism ANONYMOUS -- the witness the lease asks for.
    :ok =
      WsClient.send_binary(ws, [
        FrameCodec.encode_frame(:sasl, 0, {:sasl_init, %{mechanism: {:symbol, "ANONYMOUS"}}})
      ])

    assert {[%{type: :sasl, performative: {:sasl_outcome, %{code: 0}}}], ws, _buf} =
             recv_amqp(ws, 1, buf)

    # SASL layer done; cross to the AMQP layer through the same WS.
    :ok = WsClient.send_binary(ws, @amqp_header)
    assert {:ok, echo2, ws} = WsClient.recv_data(ws, @recv_timeout)
    assert echo2 == @amqp_header

    :ok = WsClient.send_binary(ws, [enc_frame(0, {:open, %{container_id: "ws-court"}})])
    {frames2, _ws, _} = recv_amqp(ws, 1, <<>>)
    assert [%{performative: {:open, %{container_id: server_container}}}] = frames2
    assert is_binary(server_container) and server_container != ""

    :ok = WsClient.send_binary(ws, enc_frame(0, {:end, %{}}))
  end

  test "Azure-SDK path /$servicebus/websockets upgrades and runs AMQP open" do
    port = Application.fetch_env!(:smalt, :ws_amqp_relay_port)
    ws = WsClient.connect(port, "/$servicebus/websockets")

    :ok = WsClient.send_binary(ws, @amqp_header)
    assert {:ok, echo, ws} = WsClient.recv_data(ws, @recv_timeout)
    assert echo == @amqp_header

    :ok = WsClient.send_binary(ws, [enc_frame(0, {:open, %{container_id: "sdk-path-court"}})])
    {frames, _ws, _} = recv_amqp(ws, 1, <<>>)
    assert [%{performative: {:open, _}}] = frames

    :ok = WsClient.send_binary(ws, enc_frame(0, {:end, %{}}))
  end

  # -- helpers -------------------------------------------------------------------

  defp enc_frame(ch, perf), do: IO.iodata_to_binary(FrameCodec.encode_frame(:amqp, ch, perf))

  # Pull exactly n decoded AMQP/SASL frames through the WS relay, carrying
  # the inter-frame buffer across WS data payloads. Bounded by @recv_timeout.
  defp recv_amqp(ws, n, buf \\ <<>>)
  defp recv_amqp(ws, 0, buf), do: {[], ws, buf}

  defp recv_amqp(ws, n, buf) do
    case FrameDecoder.decode_frame(buf) do
      {:ok, f, rest} ->
        {frames, ws2, rest2} = recv_amqp(ws, n - 1, rest)
        {[f | frames], ws2, rest2}

      {:more, _} ->
        assert {:ok, chunk, ws2} = WsClient.recv_data(ws, @recv_timeout)
        recv_amqp(ws2, n, buf <> chunk)

      {:error, r} ->
        flunk("amqp frame decode failed: #{inspect(r)}")
    end
  end
end
