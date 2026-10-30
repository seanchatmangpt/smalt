defmodule Smalt.Integration.RedisWireEntraAuthTest do
  @moduledoc """
  r16 court (lane S3, task c): Azure Cache Entra-ID token AUTH on the RESP2
  wire. Real :gen_tcp listener on a PRIVATE port (port 0, unnamed listener),
  real :gen_tcp client, byte-exact RESP2 assertions. Tokens are minted under
  the emulator STS key with the redis audience. No mocks, no coordination
  sleeps.
  """

  use ExUnit.Case, async: false

  alias Smalt.DataPlane.RedisWire
  alias Smalt.Identity.EntraToken

  @tid "11111111-1111-4111-8111-111111111111"
  @oid "22222222-2222-4222-8222-222222222222"
  @redis_aud "https://redis.azure.com/"
  @conn_sup EntraWireTestConnSup

  setup ctx do
    {:ok, lsock} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        backlog: 128,
        buffer: 65_536
      ])

    {:ok, sup} =
      Supervisor.start_link(
        [
          {DynamicSupervisor, name: @conn_sup, strategy: :one_for_one},
          {RedisWire.Listener, {nil, lsock}}
        ],
        strategy: :one_for_one
      )

    [{_, listener_pid, _, _} | _] = Supervisor.which_children(sup)
    port = RedisWire.Listener.port(listener_pid)

    {:ok, Map.put(ctx, :port, port)}
  end

  # -- tests ------------------------------------------------------------------

  test "AAD 2-arg token AUTH admits a minted token and keeps the keyspace", %{port: port} do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    {:ok, token, _claims} = mint_redis_token()

    send_cmd(sock, ["AUTH", @oid, token])
    assert recv_line(sock) == "+OK"

    # Entra auth is identity auth, NOT account pinning: keyspace unchanged
    # (default account), data round trip still works.
    send_cmd(sock, ["SET", "s3:entra:1", "v1"])
    assert recv_line(sock) == "+OK"
    send_cmd(sock, ["GET", "s3:entra:1"])
    assert recv_line(sock) == "$2"
    assert recv_bulk(sock, 2) == "v1"
  end

  test "AAD 1-arg AUTH user=token form admits a minted token", %{port: port} do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    {:ok, token, _claims} = mint_redis_token()

    send_cmd(sock, ["AUTH", "user=" <> token])
    assert recv_line(sock) == "+OK"
    send_cmd(sock, ["PING"])
    assert recv_line(sock) == "+PONG"
  end

  test "garbage / foreign-audience / expired tokens get the real WRONGPASS refusal", %{port: port} do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    # Garbage JWT-shaped password (signature will not verify).
    send_cmd(sock, ["AUTH", @oid, "aaa.bbb.ccc"])
    assert recv_line(sock) =~ ~r/^-ERR WRONGPASS/

    # Foreign audience: same STS, wrong resource.
    {:ok, tok2, _} = mint_redis_token(aud: "https://management.azure.com")
    send_cmd(sock, ["AUTH", @oid, tok2])
    assert recv_line(sock) =~ ~r/^-ERR WRONGPASS/

    # Expired token.
    {:ok, tok3, _} = mint_redis_token(now: System.system_time(:second) - 7200)
    send_cmd(sock, ["AUTH", @oid, tok3])
    assert recv_line(sock) =~ ~r/^-ERR WRONGPASS/
  end

  test "1-arg AUTH without = keeps the engine accept-any behavior", %{port: port} do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    send_cmd(sock, ["AUTH", "plain"])
    assert recv_line(sock) == "+OK"
    send_cmd(sock, ["PING"])
    assert recv_line(sock) == "+PONG"
  end

  test "legacy access-key AUTH is unchanged (keyspace pin intact)", %{port: port} do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    send_cmd(sock, ["AUTH", "s3acct", "s3pass"])
    assert recv_line(sock) == "+OK"
    send_cmd(sock, ["SET", "s3:legacy:1", "v1"])
    assert recv_line(sock) == "+OK"
    send_cmd(sock, ["GET", "s3:legacy:1"])
    assert recv_line(sock) == "$2"
    assert recv_bulk(sock, 2) == "v1"
  end

  # -- token mint helper -------------------------------------------------------

  defp mint_redis_token(opts \\ []) do
    aud = Keyword.get(opts, :aud, @redis_aud)
    now = Keyword.get(opts, :now) || System.system_time(:second)

    {:ok, token} =
      Smalt.Auth.StsKey.mint(%{
        "aud" => aud,
        "iss" => "https://sts.windows.net/#{@tid}/",
        "iat" => now,
        "nbf" => now,
        "exp" => now + 3600,
        "appid" => "00000000-0000-0000-0000-000000000004",
        "oid" => @oid,
        "tid" => @tid
      })

    {:ok, token, %{"aud" => aud}}
  end

  # -- wire helpers ------------------------------------------------------------

  defp send_cmd(sock, tokens) do
    bulks =
      tokens
      |> Enum.map(fn t ->
        "$" <> Integer.to_string(byte_size(t)) <> "\r\n" <> t <> "\r\n"
      end)
      |> IO.iodata_to_binary()

    :ok = :gen_tcp.send(sock, "*" <> Integer.to_string(length(tokens)) <> "\r\n" <> bulks)
  end

  # Buffered reply readers: leftover bytes of a pipelined reply segment are
  # kept per-socket in the test-process dictionary (a recv(0) consumes the
  # whole segment; discarding the remainder loses the NEXT line).
  defp recv_line(sock) do
    key = {:s3buf, sock}
    buf = Process.get(key, "")

    case :binary.split(buf, "\r\n") do
      [line, rest] ->
        Process.put(key, rest)
        line

      _ ->
        case :gen_tcp.recv(sock, 0, 2_000) do
          {:ok, data} ->
            Process.put(key, buf <> data)
            recv_line(sock)

          {:error, reason} ->
            flunk("recv failed: #{inspect(reason)}")
        end
    end
  end

  defp recv_bulk(sock, len) do
    key = {:s3buf, sock}
    buf = Process.get(key, "")
    need = len + 2

    if byte_size(buf) >= need do
      <<payload::binary-size(^len), "\r\n", rest::binary>> = buf
      Process.put(key, rest)
      payload
    else
      case :gen_tcp.recv(sock, need - byte_size(buf), 2_000) do
        {:ok, data} ->
          Process.put(key, buf <> data)
          recv_bulk(sock, len)

        {:error, reason} ->
          flunk("recv failed: #{inspect(reason)}")
      end
    end
  end
end
