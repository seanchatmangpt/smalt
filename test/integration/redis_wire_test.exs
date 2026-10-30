defmodule Smalt.Integration.RedisWireTest do
  @moduledoc """
  T01 court (v26.10.29): the RESP2 wire listener over
  `Smalt.DataPlane.AzureCache.handle/2`. CHICAGO court — a real `:gen_tcp`
  listener on a PRIVATE port (port `0`, named `nil`, never the app-env
  default 6380) and a real `:gen_tcp` client; assertions are on the
  BYTE-EXACT RESP2 replies read off the wire. No mocks, no Process.sleep —
  the client reads with protocol framing (a blocking bounded recv until the
  reply is COMPLETE, never a fixed wait).
  """

  use ExUnit.Case, async: false

  alias Smalt.DataPlane.RedisWire

  @conn_sup RedisWire.TestConnSup

  setup do
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
    # Same-process key (ExUnit runs each test in the setup process).
    Process.put(:redis_wire_port, port)
    # Teardown law: the supervisor is LINKED to this test process, and ExUnit
    # exits it with :shutdown after the test — that link IS the teardown (an
    # explicit Supervisor.stop in on_exit races that kill and fails the court).
    :ok

    {:ok, port: port}
  end

  # -- Real :gen_tcp client (no sleeps: bounded blocking recv on real bytes) -----

  defp connect(port) do
    {:ok, sock} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    sock
  end

  defp multibulk(tokens) do
    IO.iodata_to_binary([
      "*", Integer.to_string(length(tokens)), "\r\n",
      Enum.flat_map(tokens, fn t ->
        ["$", Integer.to_string(byte_size(t)), "\r\n", t, "\r\n"]
      end)
    ])
  end

  # Sends the multibulk encoding of `tokens`, reads ONE complete reply, closes.
  defp cmd(port, tokens) when is_list(tokens) do
    sock = connect(port)
    :ok = :gen_tcp.send(sock, multibulk(tokens))
    reply = recv_reply(sock)
    :gen_tcp.close(sock)
    reply
  end

  # Sends a RAW inline command line, reads ONE complete reply, closes.
  defp cmd_inline(port, line) do
    sock = connect(port)
    :ok = :gen_tcp.send(sock, line)
    reply = recv_reply(sock)
    :gen_tcp.close(sock)
    reply
  end

  # Reads a COMPLETE resp2 reply: blocking bounded recv + protocol framing.
  defp recv_reply(sock, buf \\ "") do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        buf = buf <> data

        case read_element(buf) do
          {:ok, _elem, rest} when rest == "" -> buf
          {:ok, _elem, _rest} -> buf
          :partial -> recv_reply(sock, buf)
        end

      {:error, reason} ->
        raise "recv failed: #{inspect(reason)} (buf=#{inspect(buf)})"
    end
  end

  # Parses ONE resp2 element off `bin`: {:ok, bytes, rest} | :partial | {:error, :bad}.
  defp read_element(<<"+", rest::binary>>) do
    case :binary.split(rest, "\r\n") do
      [line, more] -> {:ok, "+" <> line <> "\r\n", more}
      [_] -> :partial
    end
  end

  defp read_element(<<"-", rest::binary>>) do
    case :binary.split(rest, "\r\n") do
      [line, more] -> {:ok, "-" <> line <> "\r\n", more}
      [_] -> :partial
    end
  end

  defp read_element(<<":", rest::binary>>) do
    case :binary.split(rest, "\r\n") do
      [line, more] -> {:ok, ":" <> line <> "\r\n", more}
      [_] -> :partial
    end
  end

  defp read_element(<<"$", rest::binary>>) do
    case :binary.split(rest, "\r\n") do
      ["-1", tail] ->
        {:ok, "$-1\r\n", tail}

      [len_str, tail] ->
        len = String.to_integer(len_str)

        if byte_size(tail) >= len + 2 do
          <<bulk::binary-size(len + 2), more::binary>> = tail
          {:ok, "$" <> len_str <> "\r\n" <> bulk, more}
        else
          :partial
        end

      [_] ->
        :partial
    end
  end

  defp read_element(<<"*", rest::binary>>) do
    case :binary.split(rest, "\r\n") do
      [count_str, tail] ->
        count = String.to_integer(count_str)
        read_elements(tail, count, ["*", count_str, "\r\n"])

      [_] ->
        :partial
    end
  end

  # RESP3 map (%N): 2N elements — keys and values alternate, same framing.
  defp read_element(<<"%", rest::binary>>) do
    case :binary.split(rest, "\r\n") do
      [count_str, tail] ->
        count = String.to_integer(count_str)
        read_elements(tail, 2 * count, ["%", count_str, "\r\n"])

      [_] ->
        :partial
    end
  end

  defp read_element(_), do: {:error, :bad}

  defp read_elements(tail, 0, acc), do: {:ok, IO.iodata_to_binary(acc), tail}

  defp read_elements(tail, count, acc) do
    case read_element(tail) do
      {:ok, elem, more} -> read_elements(more, count - 1, [acc, elem])
      :partial -> :partial
      {:error, :bad} -> {:error, :bad}
    end
  end

  # -- The court -----------------------------------------------------------------

  test "PING answers +PONG\\r\\n (multibulk and inline)" do
    assert cmd(port_of(), ["PING"]) == "+PONG\r\n"
    assert cmd_inline(port_of(), "PING\r\n") == "+PONG\r\n"
    assert cmd(port_of(), ["PING", "hello"]) == "$5\r\nhello\r\n"
  end

  test "SET/GET basics, byte-exact bulk replies, binary-safe payloads" do
    key = unique("str")

    assert cmd(port_of(), ["SET", key, "v1"]) == "+OK\r\n"
    assert cmd(port_of(), ["GET", key]) == "$2\r\nv1\r\n"
    # Embedded CRLF rides the declared bulk length (binary safety through the wire).
    assert cmd(port_of(), ["SET", key, "a\r\nb"]) == "+OK\r\n"
    assert cmd(port_of(), ["GET", key]) == "$4\r\na\r\nb\r\n"
    assert cmd(port_of(), ["GET", unique("missing")]) == "$-1\r\n"
  end

  test "DEL and EXISTS" do
    key = unique("del")

    assert cmd(port_of(), ["SET", key, "x"]) == "+OK\r\n"
    assert cmd(port_of(), ["EXISTS", key]) == ":1\r\n"
    assert cmd(port_of(), ["DEL", key]) == ":1\r\n"
    assert cmd(port_of(), ["EXISTS", key]) == ":0\r\n"
    assert cmd(port_of(), ["DEL", key]) == ":0\r\n"
  end

  test "EXPIRE/TTL" do
    key = unique("ttl")

    assert cmd(port_of(), ["SET", key, "x"]) == "+OK\r\n"
    assert cmd(port_of(), ["EXPIRE", key, "100"]) == ":1\r\n"

    ttl = cmd(port_of(), ["TTL", key])
    assert Regex.match?(~r/^:\d+\r\n$/, ttl)

    # A live key with NO expiry answers :1 (integer), a missing key :2.
    assert cmd(port_of(), ["TTL", unique("ttl-noexpiry")]) in [":-1\r\n", ":-2\r\n"]
    assert cmd(port_of(), ["EXPIRE", unique("expire-missing"), "10"]) == ":0\r\n"
  end

  test "INCR: fresh, repeated, GET-after-INCR, non-integer -ERR" do
    key = unique("ctr")

    assert cmd(port_of(), ["INCR", key]) == ":1\r\n"
    assert cmd(port_of(), ["INCR", key]) == ":2\r\n"
    assert cmd(port_of(), ["GET", key]) == "$1\r\n2\r\n"

    sk = unique("nonint")
    assert cmd(port_of(), ["SET", sk, "abc"]) == "+OK\r\n"

    assert cmd(port_of(), ["INCR", sk]) ==
             "-ERR value is not an integer or out of range\r\n"
  end

  test "HSET/HGET/HGETALL (deterministic field-sorted emission)" do
    key = unique("hash")

    assert cmd(port_of(), ["HSET", key, "b", "2"]) == ":1\r\n"
    assert cmd(port_of(), ["HSET", key, "a", "1"]) == ":1\r\n"
    assert cmd(port_of(), ["HGET", key, "a"]) == "$1\r\n1\r\n"
    assert cmd(port_of(), ["HGET", key, "zz"]) == "$-1\r\n"

    assert cmd(port_of(), ["HGETALL", key]) ==
             "*4\r\n$1\r\na\r\n$1\r\n1\r\n$1\r\nb\r\n$1\r\n2\r\n"
  end

  test "LPUSH/LRANGE" do
    key = unique("list")

    assert cmd(port_of(), ["LPUSH", key, "a"]) == ":1\r\n"
    assert cmd(port_of(), ["LPUSH", key, "b"]) == ":2\r\n"
    assert cmd(port_of(), ["LRANGE", key, "0", "-1"]) == "*2\r\n$1\r\nb\r\n$1\r\na\r\n"
    assert cmd(port_of(), ["LRANGE", unique("empty-list"), "0", "-1"]) == "*0\r\n"
  end

  test "SADD/SMEMBERS (sorted emission)" do
    key = unique("set")

    assert cmd(port_of(), ["SADD", key, "zeta", "alpha"]) == ":2\r\n"
    assert cmd(port_of(), ["SADD", key, "alpha"]) == ":0\r\n"
    assert cmd(port_of(), ["SMEMBERS", key]) == "*2\r\n$5\r\nalpha\r\n$4\r\nzeta\r\n"
  end

  test "KEYS glob over the account keyspace" do
    k1 = unique("keys-a")
    k2 = unique("keys-b")

    assert cmd(port_of(), ["SET", k1, "1"]) == "+OK\r\n"
    assert cmd(port_of(), ["SET", k2, "2"]) == "+OK\r\n"

    reply = cmd(port_of(), ["KEYS", "keys-*"])
    assert String.starts_with?(reply, "*2\r\n")
    assert reply =~ "$" <> Integer.to_string(byte_size(k1)) <> "\r\n" <> k1 <> "\r\n"
    assert reply =~ "$" <> Integer.to_string(byte_size(k2)) <> "\r\n" <> k2 <> "\r\n"
  end

  test "node-redis 6 connect-time handshake: HELLO 3 map, SETINFO, MAINT_NOTIFICATIONS accepted" do
    sock = connect(port_of())
    on_exit = fn ->
      :gen_tcp.close(sock)
    end

    on_exit(on_exit)

    # Byte-captured node-redis 6.3.0 connect stream (r3 consumer court).
    :ok = :gen_tcp.send(sock, multibulk(["HELLO", "3"]))
    hello_reply = recv_reply(sock)
    # node-redis's HELLO 3 parser only accepts a RESP3 map (%); a RESP2 flat
    # array desyncs it ("Unknown RESP type 111 'o'").
    assert hello_reply =~ "proto"
    assert String.starts_with?(hello_reply, "%")

    :ok = :gen_tcp.send(sock, multibulk(["CLIENT", "SETINFO", "LIB-VER", "6.3.0"]))
    assert recv_reply(sock) == "+OK\r\n"

    :ok = :gen_tcp.send(sock, multibulk(["CLIENT", "MAINT_NOTIFICATIONS", "ON", "moving-endpoint-type", "external-ip"]))
    assert recv_reply(sock) == "+OK\r\n"
  end

  test "pipelined HELLO 3 + CLIENT SETINFO in one segment answers BOTH (r3 stall bisect)" do
    sock = connect(port_of())

    :ok =
      :gen_tcp.send(
        sock,
        multibulk(["HELLO", "3"]) <> multibulk(["CLIENT", "SETINFO", "LIB-VER", "6.3.0"])
      )

    # Raw deadline read: both replies may coalesce into one segment, so assert
    # on ONE accumulated byte stream, not on per-recv framing.
    stream = pipelined_recv(sock)

    assert stream =~ "%"
    assert stream =~ "+OK\r\n"

    :gen_tcp.close(sock)
  end

  # Accumulates until the full pipelined exchange (+OK terminator) is present.
  defp pipelined_recv(sock, buf \\ "") do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        buf = buf <> data

        if String.contains?(buf, "+OK\r\n") do
          buf
        else
          pipelined_recv(sock, buf)
        end

      {:error, reason} ->
        raise "recv failed: #{inspect(reason)} (buf=#{inspect(buf)})"
    end
  end

  test "unknown command answers -ERR" do
    assert cmd(port_of(), ["NOSUCHCMD", "x"]) == "-ERR unknown command 'NOSUCHCMD'\r\n"
  end

  test "WRONGTYPE: string key vs list op" do
    key = unique("wrongtype")

    assert cmd(port_of(), ["SET", key, "s"]) == "+OK\r\n"

    assert cmd(port_of(), ["LPUSH", key, "v"]) ==
             "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
  end

  test "AUTH selects the account keyspace; QUIT answers +OK and closes" do
    account = "wire-court-acct-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    sock = connect(port_of())

    :ok = :gen_tcp.send(sock, multibulk(["AUTH", account, "anypass"]))
    assert recv_reply(sock) == "+OK\r\n"

    key = unique("acct")
    :ok = :gen_tcp.send(sock, multibulk(["SET", key, "own-account"]))
    assert recv_reply(sock) == "+OK\r\n"
    :gen_tcp.close(sock)

    # The default-account view does NOT see the AUTHed account's key...
    assert cmd(port_of(), ["EXISTS", key]) == ":0\r\n"

    # ...and a second connection AUTHed into the SAME account DOES.
    sock2 = connect(port_of())
    :ok = :gen_tcp.send(sock2, multibulk(["AUTH", account, "anypass"]))
    assert recv_reply(sock2) == "+OK\r\n"
    :ok = :gen_tcp.send(sock2, multibulk(["GET", key]))
    assert recv_reply(sock2) == "$11\r\nown-account\r\n"

    # QUIT answers +OK; the socket is then closed by the server.
    :ok = :gen_tcp.send(sock2, multibulk(["QUIT"]))
    assert recv_reply(sock2) == "+OK\r\n"
    assert match?({:error, :closed}, :gen_tcp.recv(sock2, 0, 5_000))
  end

  test "framing: split-arriving multibulk reassembles; protocol error answers -ERR and closes" do
    sock = connect(port_of())

    # Split the frame mid-payload across two sends; the conn must reassemble.
    payload = multibulk(["ECHO", "split-payload"])
    {head, tail} = String.split_at(payload, 5)
    :ok = :gen_tcp.send(sock, head)
    :ok = :gen_tcp.send(sock, tail)
    assert recv_reply(sock) == "$13\r\nsplit-payload\r\n"

    # Bad multibulk header: unrecoverable -> -ERR then server-side close.
    :ok = :gen_tcp.send(sock, "*garbage\r\n")
    assert recv_reply(sock) == "-ERR protocol error\r\n"
    assert match?({:error, :closed}, :gen_tcp.recv(sock, 0, 5_000))
  end

  # -- Helpers -------------------------------------------------------------------

  defp port_of, do: Process.get(:redis_wire_port)

  defp unique(prefix),
    do: prefix <> "-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
