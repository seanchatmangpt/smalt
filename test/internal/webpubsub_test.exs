# AZ-5 court: Azure Web PubSub face over the landed BK-58 WS substrate.
#
# Chicago discipline: real RFC6455 client over real TCP (hand-rolled, no
# WS library), real Bandit router, real HS256 JWT minted by the router,
# real group registry + server push, real CloudEvents POSTs (inets :httpc)
# to a test-owned plug on loopback. No mocks.
#
# Context: solo (in-process wire faces on loopback).

Code.require_file("poll_helper.exs", __DIR__)

defmodule SmaltTest.WpsClient do
  @moduledoc """
  RFC6455 client variant for the Web PubSub face: JSON text frames +
  binary receive, subprotocol-offering handshake. BK-58 hand-rolled
  client pattern (SmaltTest.WsClient), self-contained variant.
  """

  import ExUnit.Assertions
  import Bitwise

  defstruct [:sock, :buf]

  def connect(port, path, opts \\ []) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    sub =
      if Keyword.get(opts, :subprotocol, true),
        do: "Sec-WebSocket-Protocol: json.webpubsub.azure.v1\r\n",
        else: ""

    req =
      "GET #{path} HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        sub <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n\r\n"

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    :ok = :gen_tcp.send(sock, req)
    {:ok, headers, rest} = recv_until_marker(sock, "", "\r\n\r\n")
    assert String.contains?(headers, " 101 "), "expected 101, got: #{inspect(headers)}"
    %__MODULE__{sock: sock, buf: rest}
  end

  def send_text(%__MODULE__{sock: sock}, data) do
    frame(sock, 0x81, data)
  end

  # Returns the next JSON message (text frame) or {:binary, bytes}.
  def recv(ws, timeout_ms) do
    case next_frame(ws) do
      {:ok, {:text, payload}, ws2} -> {:ok, Jason.decode!(payload), ws2}
      {:ok, {:binary, payload}, ws2} -> {:ok, {:binary, payload}, ws2}
      {:ok, {:ping, p}, ws2} ->
        frame(ws2.sock, 0x8A, p)
        recv(%{ws2 | buf: ""}, timeout_ms)
      {:more, ws2} ->
        case :gen_tcp.recv(ws2.sock, 0, timeout_ms) do
          {:ok, chunk} -> recv(%{ws2 | buf: ws2.buf <> chunk}, timeout_ms)
          {:error, :closed} -> {:closed, ws2}
          {:error, r} -> {:error, r, ws2}
        end
      {:closed, _} = c -> c
    end
  end

  def close(%__MODULE__{sock: sock}), do: :gen_tcp.close(sock)

  defp frame(sock, opcode, payload) do
    data = IO.iodata_to_binary(payload)
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(data)

    head =
      if len < 126, do: <<opcode, 0x80 ||| len>>, else: <<opcode, 0x80 ||| 126, len::16>>

    payload = :crypto.exor(data, mask_stream(mask, len))
    :ok = :gen_tcp.send(sock, <<head::binary, mask::binary, payload::binary>>)
  end

  defp next_frame(%{buf: buf} = ws) do
    case parse_frame(buf) do
      {frame, rest} -> {:ok, frame, %{ws | buf: rest}}
      :more -> {:more, ws}
      :invalid -> {:closed, ws}
    end
  end

  defp parse_frame(<<b1::8, b2::8, rest::binary>>) do
    len7 = b2 &&& 0x7F

    case {len7, rest} do
      {126, <<len::16, payload::binary>>} -> take(len, payload, b1)
      {127, <<_::32, len::32, payload::binary>>} -> take(len, payload, b1)
      {len, payload} -> take(len, payload, b1)
    end
  end

  defp parse_frame(_), do: :more

  defp take(len, payload, b1) do
    case payload do
      <<p2::binary-size(^len), tail::binary>> -> emit_frame(b1, p2, tail)
      _ -> :more
    end
  end

  defp emit_frame(b1, payload, tail) do
    opcode = b1 &&& 0x0F

    frame =
      cond do
        opcode == 9 -> {:ping, payload}
        opcode == 10 -> {:pong, payload}
        opcode == 8 -> {:close, payload}
        opcode == 1 -> {:text, payload}
        opcode == 2 -> {:binary, payload}
      end

    {frame, tail}
  end

  defp mask_stream(mask, len) do
    :binary.part(:binary.copy(mask, div(len, 4) + 1), 0, len)
  end

  defp recv_until_marker(sock, buf, marker) do
    case :binary.split(buf, marker) do
      [headers, tail] -> {:ok, headers, tail}
      _ ->
        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, chunk} -> recv_until_marker(sock, buf <> chunk, marker)
          {:error, r} -> {:error, r}
        end
    end
  end
end

defmodule Smalt.Internal.WebPubSubTest do
  use ExUnit.Case, async: false

  alias SmaltTest.WpsClient

  @recv_timeout 10_000
  @wal_frame :binary.copy(<<0xAB>>, 41)

  defmodule WpsHandler do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/events" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(WpsEvents, &[{conn.req_headers, body} | &1])
      send_resp(conn, 200, "")
    end

    match _ do
      send_resp(conn, 404, "")
    end
  end

  setup_all do
    port = probe_port()

    {:ok, _} = Agent.start_link(fn -> [] end, name: WpsEvents)
    {:ok, _} = Bandit.start_link(plug: WpsHandler, scheme: :http, port: port)

    Application.put_env(:smalt, :web_pubsub_event_handler_url, "http://127.0.0.1:#{port}/events")
    :ok
  end

  defp probe_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp wps_port, do: Application.fetch_env!(:smalt, :web_pubsub_port)

  defp base, do: "http://127.0.0.1:#{wps_port()}"

  # KD-169: server faces are credential-gated — mint the real HS256 Bearer
  # JWT (aud = https://<host>) the real server SDKs send.
  defp server_auth_header do
    aud = "https://127.0.0.1:#{wps_port()}"
    now = System.system_time(:second)
    claims = %{"aud" => aud, "exp" => now + 600}
    signer = Joken.Signer.create("HS256", server_access_key())
    {:ok, jwt} = Joken.Signer.sign(claims, signer)
    [{~c"authorization", String.to_charlist("Bearer " <> jwt)}]
  end

  defp server_access_key,
    do: Application.get_env(:smalt, :web_pubsub_access_key, "smalt-wps-dev-access-key")

  defp post_json(path) do
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:post, {String.to_charlist(base() <> path), server_auth_header(), ~c"application/json", ""}, [], [])

    Jason.decode!(body)
  end

  defp push_wal(hub, group, batch) do
    {:ok, {{_, status, _}, _, body}} =
      :httpc.request(
        :post,
        {String.to_charlist(base() <> "/webpubsub/hubs/#{hub}/groups/#{group}/:send"),
         server_auth_header(), ~c"application/octet-stream", batch},
        [],
        []
      )

    {status, Jason.decode!(body)}
  end

  defp join_two(hub, tok) do
    c1 = WpsClient.connect(wps_port(), "/webpubsub/hubs/#{hub}?access_token=#{tok}")
    c2 = WpsClient.connect(wps_port(), "/webpubsub/hubs/#{hub}?access_token=#{tok}")

    :ok = WpsClient.send_text(c1, Jason.encode!(%{"type" => "joinGroup", "group" => "sync", "ackId" => 1}))
    :ok = WpsClient.send_text(c2, Jason.encode!(%{"type" => "joinGroup", "group" => "sync", "ackId" => 2}))

    assert {:ok, %{"type" => "ack", "success" => true}, c1} = WpsClient.recv(c1, @recv_timeout)
    assert {:ok, %{"type" => "ack", "success" => true}, c2} = WpsClient.recv(c2, @recv_timeout)
    {:ok, c1, c2}
  end

  defp hdr(headers, name) do
    case Enum.find(headers, fn {k, _} -> k == name end) do
      {_, v} -> v
      nil -> nil
    end
  end

  # -- Courts -------------------------------------------------------------------

  test "generateToken mints a verifiable JWT with webpubsub.role claims" do
    hub = "az5-hub-#{System.unique_integer([:positive])}"

    %{"token" => token} =
      post_json("/webpubsub/hubs/#{hub}/generateToken?userId=az5-u1&role=webpubsub.joinLeaveGroup.sync")

    assert {:ok, "az5-u1", roles} = Smalt.WebPubSub.Token.verify(hub, token)
    assert roles == ["webpubsub.joinLeaveGroup.sync"]
  end

  test "negotiate returns a client access URL carrying the token" do
    hub = "az5-hub-#{System.unique_integer([:positive])}"
    %{"url" => url, "accessToken" => token} = post_json("/webpubsub/hubs/#{hub}/negotiate?userId=az5-u2")
    assert url =~ "access_token="
    assert {:ok, _, _} = Smalt.WebPubSub.Token.verify(hub, token)
  end

  test "two clients join group sync; server push delivers byte-exact WAL frames to BOTH (AZ-5 witness)" do
    hub = "az5-hub-#{System.unique_integer([:positive])}"

    %{"token" => tok} =
      post_json("/webpubsub/hubs/#{hub}/generateToken?userId=w1&role=webpubsub.joinLeaveGroup.sync")

    {:ok, c1, c2} = join_two(hub, tok)

    # Server push via the real REST face: 3-frame WAL batch, octet-stream,
    # raw bytes broadcast to every group member.
    batch = IO.iodata_to_binary([@wal_frame, @wal_frame, @wal_frame])
    assert {202, %{"delivered" => 2}} = push_wal(hub, "sync", batch)

    assert {:ok, {:binary, ^batch}, c1} = WpsClient.recv(c1, @recv_timeout)
    assert {:ok, {:binary, ^batch}, c2} = WpsClient.recv(c2, @recv_timeout)

    WpsClient.close(c1)
    WpsClient.close(c2)
  end

  test "un-permissioned sendToGroup is refused with the typed subprotocol error" do
    hub = "az5-hub-#{System.unique_integer([:positive])}"

    # Token carries ONLY the join role: no sendToGroup.sync.
    %{"token" => tok} =
      post_json("/webpubsub/hubs/#{hub}/generateToken?userId=w2&role=webpubsub.joinLeaveGroup.sync")

    {:ok, c1, c2} = join_two(hub, tok)

    :ok =
      WpsClient.send_text(
        c1,
        Jason.encode!(%{"type" => "sendToGroup", "group" => "sync", "data" => "nope", "ackId" => 7})
      )

    assert {:ok,
            %{"type" => "ack", "ackId" => 7, "success" => false,
             "error" => %{"name" => "Forbidden"}},
            c1} = WpsClient.recv(c1, @recv_timeout)

    # The denial must NOT broadcast anything to group members: bounded
    # poll, c2 sees silence within the window (an unexpected delivery
    # fails the court).
    assert {:error, :timeout, _c2} = WpsClient.recv(c2, 1_500)

    WpsClient.close(c1)
    WpsClient.close(c2)
  end

  test "connect/disconnect CloudEvents witnessed at the upstream handler" do
    hub = "az5-hub-#{System.unique_integer([:positive])}"

    %{"token" => tok} =
      post_json("/webpubsub/hubs/#{hub}/generateToken?userId=w3&role=webpubsub.joinLeaveGroup.sync")

    c = WpsClient.connect(wps_port(), "/webpubsub/hubs/#{hub}?access_token=#{tok}")
    :ok = WpsClient.close(c)

    evs = await_events(hub, 3)
    types = Enum.map(evs, fn {hs, _b} -> hdr(hs, "ce-type") end)

    assert "azure.webpubsub.sys.connect" in types
    assert "azure.webpubsub.sys.connected" in types
    assert "azure.webpubsub.sys.disconnected" in types
    assert Enum.all?(evs, fn {hs, _} -> hdr(hs, "ce-specversion") == "1.0" end)
    assert Enum.all?(evs, fn {hs, _} -> hdr(hs, "ce-hub") == hub end)
  end

  # Bounded poll via the audited poll implementation (no-sleep doctrine).
  defp await_events(hub, n, deadline_ms \\ 5_000) do
    case SmaltTest.Internal.Poll.eventually(
           fn ->
             evs = Enum.filter(Agent.get(WpsEvents, & &1), fn {hs, _} -> hdr(hs, "ce-hub") == hub end)

             if length(evs) >= n, do: {:ok, evs}, else: :pending
           end,
           timeout_ms: deadline_ms
         ) do
      {:ok, evs} -> evs
      {:timeout, _} -> flunk("timed out waiting for #{n} cloudevents for hub #{hub}")
    end
  end

  # -- EXPL-4 repair courts (expl4r-wirefront-repairs) ---------------------------

  # F1 falsifier: a no-aud/no-exp/no-nbf/no-sub JWT must verify to :error —
  # the witnessed fail-open face (expl4-wirefronts-errc: ADMITTED, uid=""
  # roles=[...]) is closed. Also: empty sub refused, wrong-aud (cross-hub)
  # refused, and a full-claims mint still verifies.
  test "F1: token verify fails closed on absent/empty/wrong claims" do
    now = System.system_time(:second)
    signer = Joken.Signer.create("HS256", "smalt-wps-dev-access-key")

    hand_sign = fn claims ->
      {:ok, t} = Joken.Signer.sign(claims, signer)
      t
    end

    hub = "expl4-f1-#{System.unique_integer([:positive])}"

    # The witnessed hostile token: no aud, no exp, no nbf, no sub.
    bare = hand_sign.(%{"webpubsub.role" => ["webpubsub.sendToGroup"]})
    assert :error = Smalt.WebPubSub.Token.verify(hub, bare)

    # present-but-empty sub refused.
    empty_sub = hand_sign.(%{"aud" => "/webpubsub/hubs/#{hub}", "sub" => "", "exp" => now + 600})
    assert :error = Smalt.WebPubSub.Token.verify(hub, empty_sub)

    # present-but-wrong aud (hub-B token on hub A) refused.
    wrong_aud =
      hand_sign.(%{"aud" => "/webpubsub/hubs/other-hub", "sub" => "u", "exp" => now + 600})

    assert :error = Smalt.WebPubSub.Token.verify(hub, wrong_aud)

    # absent exp (valid aud/sub/nbf) refused — never-expires face closed.
    no_exp = hand_sign.(%{"aud" => "/webpubsub/hubs/#{hub}", "sub" => "u"})
    assert :error = Smalt.WebPubSub.Token.verify(hub, no_exp)

    # happy path unchanged: full-claims mint verifies.
    good =
      hand_sign.(%{
        "aud" => "/webpubsub/hubs/#{hub}",
        "sub" => "u1",
        "exp" => now + 600,
        "nbf" => now - 60,
        "webpubsub.role" => ["webpubsub.sendToGroup.g"]
      })

    assert {:ok, "u1", ["webpubsub.sendToGroup.g"]} = Smalt.WebPubSub.Token.verify(hub, good)
  end

  # F6 falsifier: sendToGroup with a missing "group" key must answer the
  # protocol error frame and leave the socket ALIVE (the pre-fix face was a
  # FunctionClauseError kill), and leaveGroup is permission-checked
  # symmetric to joinGroup.
  test "F6: missing-key dispatch answers the error frame, socket stays alive; leave is permission-checked" do
    hub = "expl4-f6-#{System.unique_integer([:positive])}"

    %{"token" => tok} =
      post_json("/webpubsub/hubs/#{hub}/generateToken?userId=f6&role=webpubsub.joinLeaveGroup.sync")

    c1 = WpsClient.connect(wps_port(), "/webpubsub/hubs/#{hub}?access_token=#{tok}")

    # missing-key sendToGroup: error frame, socket alive.
    :ok =
      WpsClient.send_text(c1, Jason.encode!(%{"type" => "sendToGroup", "ackId" => 9, "data" => "x"}))

    assert {:ok,
            %{"type" => "ack", "ackId" => 9, "success" => false,
             "error" => %{"name" => "InvalidMessage"}},
            c1} = WpsClient.recv(c1, @recv_timeout)

    # socket still serves frames after the invalid message.
    :ok =
      WpsClient.send_text(
        c1,
        Jason.encode!(%{"type" => "joinGroup", "group" => "sync", "ackId" => 10})
      )

    assert {:ok, %{"type" => "ack", "ackId" => 10, "success" => true}, c1} =
             WpsClient.recv(c1, @recv_timeout)

    # leaveGroup WITHOUT the permission: Forbidden ack (symmetry with join).
    :ok =
      WpsClient.send_text(
        c1,
        Jason.encode!(%{"type" => "leaveGroup", "group" => "other", "ackId" => 11})
      )

    assert {:ok,
            %{"type" => "ack", "ackId" => 11, "success" => false,
             "error" => %{"name" => "Forbidden"}},
            c1} = WpsClient.recv(c1, @recv_timeout)

    WpsClient.close(c1)
  end

end
