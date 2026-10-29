# KD-169R court: server-credential gate on the Web PubSub server API faces
# (generateToken / negotiate / groups :send) — KD-169 close condition.
#
# Chicago discipline: real Bandit wire (the app-booted face on its real
# port), real HTTP over loopback (:httpc), real Joken HS256, real client
# WS upgrade leg (raw RFC6455 handshake). No mocks, no sleeps.
#
# Context: solo (in-process wire faces on loopback).

defmodule Smalt.Internal.Kd169rCredGateTest do
  use ExUnit.Case, async: false

  @access_key Application.get_env(:smalt, :web_pubsub_access_key, "smalt-wps-dev-access-key")

  setup_all do
    port = Application.fetch_env!(:smalt, :web_pubsub_port)
    {:ok, port: port, base: "http://127.0.0.1:#{port}"}
  end

  defp server_jwt(base, opts \\ []) do
    aud = Keyword.get(opts, :aud, "https://127.0.0.1:#{Application.fetch_env!(:smalt, :web_pubsub_port)}")
    key = Keyword.get(opts, :key, @access_key)
    exp = System.system_time(:second) + Keyword.get(opts, :ttl, 600)
    claims = %{"aud" => aud, "exp" => exp}
    signer = Joken.Signer.create("HS256", key)
    {:ok, jwt} = Joken.Signer.sign(claims, signer)
    jwt
  end

  defp post(base, path, headers, body \\ "") do
    ctype = if body == "", do: ~c"application/json", else: ~c"application/octet-stream"

    headers =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    {:ok, {{_, status, _}, _, resp}} =
      :httpc.request(
        :post,
        {String.to_charlist(base <> path), headers, ctype, body},
        [],
        []
      )

    {status, resp}
  end

  defp get_status(port, path) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    req =
      "GET #{path} HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n\r\n"

    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)
    :ok = :gen_tcp.send(sock, req)
    {:ok, head} = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)
    head
  end

  # -- KD-169 gate legs -----------------------------------------------------------

  test "valid Bearer server JWT admits generateToken (token verifies, roles round-trip)", %{base: base} do
    hub = "kd169r-#{System.unique_integer([:positive])}"
    auth = [{"authorization", "Bearer " <> server_jwt(base)}]

    {200, body} = post(base, "/webpubsub/hubs/#{hub}/generateToken?userId=kd169r-u1&role=webpubsub.joinLeaveGroup.sync", auth)

    assert %{"token" => token} = Jason.decode!(body)
    assert {:ok, "kd169r-u1", ["webpubsub.joinLeaveGroup.sync"]} = Smalt.WebPubSub.Token.verify(hub, token)
  end

  test "absent credential => typed 401 naming the face (generateToken)", %{base: base} do
    hub = "kd169r-#{System.unique_integer([:positive])}"
    {401, body} = post(base, "/webpubsub/hubs/#{hub}/generateToken?userId=u", [])

    assert %{"error" => err, "face" => "generateToken"} = Jason.decode!(body)
    assert err =~ "missing server credential"
  end

  test "wrong SharedAccessKey => 401", %{base: base} do
    hub = "kd169r-#{System.unique_integer([:positive])}"
    auth = [{"authorization", "SharedAccessKey " <> Base.encode64(:crypto.strong_rand_bytes(32))}]
    {401, body} = post(base, "/webpubsub/hubs/#{hub}/generateToken?userId=u", auth)

    assert %{"error" => err, "face" => "generateToken"} = Jason.decode!(body)
    assert err =~ "access key mismatch"
  end

  test "valid SharedAccessKey admits negotiate; negotiate URL still carries the client token", %{base: base} do
    hub = "kd169r-#{System.unique_integer([:positive])}"
    auth = [{"authorization", "SharedAccessKey " <> @access_key}]

    {200, body} = post(base, "/webpubsub/hubs/#{hub}/negotiate?userId=kd169r-u2", auth)
    assert %{"url" => url, "accessToken" => token} = Jason.decode!(body)
    assert url =~ "access_token="
    assert {:ok, "kd169r-u2", _} = Smalt.WebPubSub.Token.verify(hub, token)
  end

  test "Bearer with wrong audience => 401", %{base: base} do
    hub = "kd169r-#{System.unique_integer([:positive])}"
    jwt = server_jwt(base, aud: "https://foreign.example")
    {401, body} = post(base, "/webpubsub/hubs/#{hub}/negotiate", [{"authorization", "Bearer " <> jwt}])

    assert %{"error" => err, "face" => "negotiate"} = Jason.decode!(body)
    assert err =~ "bad signature, audience, or expiry"
  end

  test "expired Bearer => 401", %{base: base} do
    hub = "kd169r-#{System.unique_integer([:positive])}"
    jwt = server_jwt(base, ttl: -60)
    {401, body} = post(base, "/webpubsub/hubs/#{hub}/negotiate", [{"authorization", "Bearer " <> jwt}])

    assert %{"face" => "negotiate"} = Jason.decode!(body)
  end

  test "groups :send requires the credential (401 absent, 202 with valid Bearer)", %{base: base, port: port} do
    hub = "kd169r-#{System.unique_integer([:positive])}"
    auth = [{"authorization", "Bearer " <> server_jwt(base)}]

    {401, body} = post(base, "/webpubsub/hubs/#{hub}/groups/sync/:send", [], <<1, 2, 3>>)
    assert %{"face" => "groups:send"} = Jason.decode!(body)

    {202, _} = post(base, "/webpubsub/hubs/#{hub}/groups/sync/:send", auth, <<1, 2, 3>>)
    # unknown action still 404s under a valid credential
    {404, _} = post(base, "/webpubsub/hubs/#{hub}/groups/sync/:nope", auth, <<>>)
    _ = port
  end

  # -- client-token flows unaffected ------------------------------------------------

  test "client WS upgrade face unchanged: valid client token => 101, bad token => 401 (no server cred needed)", %{port: port} do
    hub = "kd169r-#{System.unique_integer([:positive])}"

    token = Smalt.WebPubSub.Token.mint(hub, "kd169r-ws", ["webpubsub.joinLeaveGroup.sync"])
    head = get_status(port, "/webpubsub/hubs/#{hub}?access_token=#{token}")
    assert head =~ " 101 "

    bad = get_status(port, "/webpubsub/hubs/#{hub}?access_token=not-a-token")
    assert bad =~ " 401 "
  end
end
