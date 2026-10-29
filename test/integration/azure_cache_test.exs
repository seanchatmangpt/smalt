defmodule Smalt.Integration.AzureCacheTest do
  # r15 — T-06 (REVISED) court: Azure Cache for Redis emulation on the
  # ELIXIR-ECOSYSTEM Cachex backing. No socket anywhere — the RESP wire
  # listener was DROPPED by user direction (2026-10-29); this court calls the
  # engine DIRECTLY and asserts on the RESP2-encoded command replies so the
  # command SEMANTICS stay byte-court-able.
  #
  # Isolation law: every test uses a UNIQUE account (its own named Cachex
  # instance) — no cross-test key bleed, no flush verb needed.
  #
  # NOTE for the integrator: this court (and the engine's Cachex calls) is
  # RUNTIME-dead until `{:cachex, "~> 4.0"}` lands in mix.exs — see
  # docs/jira/v26.10.28/receipts/r15-t06-redis.md for the exact dep patch.
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.AzureCache

  setup do
    account = "court-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    {:ok, account: account}
  end

  # -- Minimal RESP2 decoder (assertions decode the engine's encoded replies) --

  defp dec(bin) when is_binary(bin) do
    {term, rest} = parse_resp(bin)
    assert rest == ""
    term
  end

  defp parse_resp(<<?+, rest::binary>>) do
    {line, rest} = resp_line(rest)
    {{:simple, line}, rest}
  end

  defp parse_resp(<<?-, rest::binary>>) do
    {line, rest} = resp_line(rest)
    {{:error_reply, line}, rest}
  end

  defp parse_resp(<<?:, rest::binary>>) do
    {line, rest} = resp_line(rest)
    {{:integer, String.to_integer(line)}, rest}
  end

  defp parse_resp(<<?$, rest::binary>>) do
    {line, rest} = resp_line(rest)
    n = String.to_integer(line)

    if n < 0 do
      {{:bulk, nil}, rest}
    else
      <<data::binary-size(n), "\r\n", rest::binary>> = rest
      {{:bulk, data}, rest}
    end
  end

  defp parse_resp(<<?*, rest::binary>>) do
    {line, rest} = resp_line(rest)
    n = String.to_integer(line)
    {items, rest} = Enum.map_reduce(1..n//1, rest, fn _, acc -> parse_resp(acc) end)
    {{:array, Enum.map(items, fn {t, _} -> t end)}, rest}
  end

  defp resp_line(bin) do
    case :binary.split(bin, "\r\n") do
      [line, rest] -> {line, rest}
      [line] -> {line, ""}
    end
  end

  # -- Strings --------------------------------------------------------------------

  test "SET/GET round-trip + DEL/EXISTS over the Cachex-backed keyspace", %{account: account} do
    assert {:ok, "+OK\r\n"} = AzureCache.handle(account, ["SET", "k", "v"])
    assert {:ok, wire} = AzureCache.handle(account, ["GET", "k"])
    assert {:bulk, "v"} = dec(wire)

    assert {:ok, ":1\r\n"} = AzureCache.handle(account, ["EXISTS", "k"])
    assert {:ok, ":1\r\n"} = AzureCache.handle(account, ["DEL", "k"])
    assert {:ok, wire} = AzureCache.handle(account, ["GET", "k"])
    assert {:bulk, nil} = dec(wire)
    assert {:ok, ":0\r\n"} = AzureCache.handle(account, ["EXISTS", "k"])
  end

  test "INCR/DECR are atomic via Cachex.incr/decr; non-integer strings refuse", %{
    account: account
  } do
    assert {:ok, ":1\r\n"} = AzureCache.handle(account, ["INCR", "n"])
    assert {:ok, ":2\r\n"} = AzureCache.handle(account, ["INCR", "n"])
    assert {:ok, ":1\r\n"} = AzureCache.handle(account, ["DECR", "n"])

    assert {:ok, "+OK\r\n"} = AzureCache.handle(account, ["SET", "s", "abc"])
    assert {:error, wire} = AzureCache.handle(account, ["INCR", "s"])
    assert {:error_reply, msg} = dec(wire)
    assert msg =~ "value is not an integer"
  end

  test "EXPIRE/TTL semantics ride the Cachex millisecond TTL", %{account: account} do
    assert {:ok, "+OK\r\n"} = AzureCache.handle(account, ["SET", "k", "v"])
    assert {:ok, ":1\r\n"} = AzureCache.handle(account, ["EXPIRE", "k", "5"])

    assert {:ok, wire} = AzureCache.handle(account, ["TTL", "k"])
    assert {:integer, ttl} = dec(wire)
    assert ttl in 1..5

    # missing key: -2; live key without expiry: -1; missing EXPIRE target: 0
    assert {:ok, ":-2\r\n"} = AzureCache.handle(account, ["TTL", "missing"])
    assert {:ok, "+OK\r\n"} = AzureCache.handle(account, ["SET", "plain", "v"])
    assert {:ok, ":-1\r\n"} = AzureCache.handle(account, ["TTL", "plain"])
    assert {:ok, ":0\r\n"} = AzureCache.handle(account, ["EXPIRE", "missing", "5"])
  end

  # -- Structures -----------------------------------------------------------------

  test "LPUSH/RPUSH/LRANGE keep list order in one Cachex value", %{account: account} do
    assert {:ok, ":1\r\n"} = AzureCache.handle(account, ["LPUSH", "l", "a"])
    assert {:ok, ":2\r\n"} = AzureCache.handle(account, ["LPUSH", "l", "b"])
    assert {:ok, ":3\r\n"} = AzureCache.handle(account, ["RPUSH", "l", "c"])

    assert {:ok, wire} = AzureCache.handle(account, ["LRANGE", "l", "0", "-1"])
    assert {:array, [{:bulk, "b"}, {:bulk, "a"}, {:bulk, "c"}]} = dec(wire)

    assert {:ok, wire} = AzureCache.handle(account, ["LRANGE", "l", "1", "2"])
    assert {:array, [{:bulk, "a"}, {:bulk, "c"}]} = dec(wire)
  end

  test "SADD/SMEMBERS round-trip (deterministic sorted emission)", %{account: account} do
    assert {:ok, ":2\r\n"} = AzureCache.handle(account, ["SADD", "s", "m2", "m1"])
    # re-adding an existing member is not new
    assert {:ok, ":0\r\n"} = AzureCache.handle(account, ["SADD", "s", "m1"])
    assert {:ok, ":1\r\n"} = AzureCache.handle(account, ["SADD", "s", "m3"])

    assert {:ok, wire} = AzureCache.handle(account, ["SMEMBERS", "s"])

    assert {:array, members} = dec(wire)
    assert Enum.map(members, fn {:bulk, m} -> m end) == ["m1", "m2", "m3"]
  end

  test "HSET/HGET/HGETALL hash semantics", %{account: account} do
    assert {:ok, ":2\r\n"} =
             AzureCache.handle(account, ["HSET", "h", "f1", "v1", "f2", "v2"])

    assert {:ok, wire} = AzureCache.handle(account, ["HGET", "h", "f1"])
    assert {:bulk, "v1"} = dec(wire)

    # overwriting an existing field is not a NEW field
    assert {:ok, ":0\r\n"} = AzureCache.handle(account, ["HSET", "h", "f1", "v1b"])
    assert {:ok, wire} = AzureCache.handle(account, ["HGET", "h", "f1"])
    assert {:bulk, "v1b"} = dec(wire)

    assert {:ok, wire} = AzureCache.handle(account, ["HGETALL", "h"])

    assert {:array, [{:bulk, "f1"}, {:bulk, "v1b"}, {:bulk, "f2"}, {:bulk, "v2"}]} = dec(wire)

    assert {:ok, wire} = AzureCache.handle(account, ["HGET", "h", "nope"])
    assert {:bulk, nil} = dec(wire)
  end

  test "WRONGTYPE is enforced by the entry tag (string vs list)", %{account: account} do
    assert {:ok, "+OK\r\n"} = AzureCache.handle(account, ["SET", "k", "v"])
    assert {:error, wire} = AzureCache.handle(account, ["LPUSH", "k", "x"])
    assert {:error_reply, msg} = dec(wire)
    assert msg =~ "WRONGTYPE"

    assert {:ok, ":1\r\n"} = AzureCache.handle(account, ["RPUSH", "l", "x"])
    assert {:error, wire} = AzureCache.handle(account, ["GET", "l"])
    assert {:error_reply, msg} = dec(wire)
    assert msg =~ "WRONGTYPE"
  end

  # -- Keyspace enumeration ---------------------------------------------------------

  test "KEYS pattern matches with * (sorted)", %{account: account} do
    for k <- ["a:1", "a:2", "b:1"] do
      assert {:ok, "+OK\r\n"} = AzureCache.handle(account, ["SET", k, "v-" <> k])
    end

    assert {:ok, wire} = AzureCache.handle(account, ["KEYS", "a:*"])
    assert {:array, [{:bulk, "a:1"}, {:bulk, "a:2"}]} = dec(wire)

    assert {:ok, wire} = AzureCache.handle(account, ["KEYS", "*"])
    assert {:array, keys} = dec(wire)
    assert length(keys) == 3

    # ? glob: exactly one wildcard character
    assert {:ok, wire} = AzureCache.handle(account, ["KEYS", "a:?"])
    assert {:array, [{:bulk, "a:1"}, {:bulk, "a:2"}]} = dec(wire)
  end

  test "SCAN cursor simple form answers the full page with cursor 0", %{account: account} do
    for k <- ["s:1", "s:2"] do
      assert {:ok, "+OK\r\n"} = AzureCache.handle(account, ["SET", k, "v"])
    end

    assert {:ok, wire} = AzureCache.handle(account, ["SCAN", "0"])
    assert {:array, [{:bulk, "0"} | rest]} = dec(wire)
    assert length(rest) == 2

    assert {:ok, wire} = AzureCache.handle(account, ["SCAN", "0", "MATCH", "s:*"])
    assert {:array, [{:bulk, "0"}, {:bulk, "s:1"}, {:bulk, "s:2"}]} = dec(wire)
  end

  # -- INFO / handshake ---------------------------------------------------------------

  test "INFO server section reports the honest Cachex/Elixir backing", %{account: account} do
    assert {:ok, wire} = AzureCache.handle(account, ["INFO"])
    assert {:bulk, info} = dec(wire)

    assert info =~ "redis_version:smalt-cachex-"
    assert info =~ "os:beam"
    assert info =~ "tcp_port:0"
    assert info =~ "run_id:"
    assert info =~ "azure_backing:cachex-"
  end

  test "HELLO serves proto 2 and REFUSES HELLO 3 (RESP2-only law retained)", %{
    account: account
  } do
    assert {:ok, wire} = AzureCache.handle(account, ["HELLO"])
    assert {:array, hello} = dec(wire)
    assert hello == [{:bulk, "server"}, {:bulk, "redis"}, {:bulk, "version"} | _]
    assert {:bulk, "2"} = Enum.at(hello, Enum.find_index(hello, &match?({:bulk, "2"}, &1)) - 1)

    assert {:error, wire} = AzureCache.handle(account, ["HELLO", "3"])
    assert {:error_reply, msg} = dec(wire)
    assert msg =~ "NOPROTO"
  end

  test "AUTH accepts any password (keys are advisory — documented divergence)", %{
    account: account
  } do
    assert {:ok, "+OK\r\n"} = AzureCache.handle(account, ["AUTH", "any-password-whatsoever"])
    assert {:ok, "+OK\r\n"} = AzureCache.handle(account, ["AUTH", "user", "pw"])
  end

  # -- Cachex instance lifecycle -------------------------------------------------------

  test "cache_start/1 is idempotent and cache_child_spec/1 embeds Cachex", %{account: account} do
    assert {:ok, pid} = AzureCache.cache_start(account)
    assert is_pid(pid)
    assert {:ok, ^pid} = AzureCache.cache_start(account)

    spec = AzureCache.cache_child_spec(account)
    assert {Cachex, :start_link, [name, [transactions: true]]} = spec.start
    assert name == String.to_atom("smalt_azure_cache_" <> account)
  end

  # -- ARM control-plane face ------------------------------------------------------------

  test "registry/1 creates the ARM record; keys are Store-backed stable", %{account: account} do
    assert {:ok, record} = AzureCache.registry(account)

    assert record["type"] == "Microsoft.Cache/Redis"
    assert record["name"] == account
    assert record["id"] =~ "providers/Microsoft.Cache/Redis/#{account}"

    props = record["properties"]
    assert props["hostName"] == "127.0.0.1"
    assert props["provisioningState"] == "Succeeded"
    assert String.length(props["primaryKey"]) == 44
    assert String.length(props["secondaryKey"]) == 44
    refute props["primaryKey"] == props["secondaryKey"]

    # honest divergence: endpoints name the BEAM accessor, no wire port
    assert props["endpoints"]["moduleName"] == "Smalt.DataPlane.AzureCache"
    assert props["endpoints"]["account"] == account
    assert props["wireListener"] == "none"
    assert props["port"] == 0

    # second call returns the SAME record (keys stable — Store-backed)
    assert {:ok, ^record} = AzureCache.registry(account)

    # list-keys face agrees with the record
    assert {:ok, %{"primaryKey" => pk, "secondaryKey" => sk}} = AzureCache.list_keys(account)
    assert pk == props["primaryKey"]
    assert sk == props["secondaryKey"]
  end
end
