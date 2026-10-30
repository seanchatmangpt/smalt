defmodule Smalt.DataPlane.AzureCache do
  @moduledoc """
  Azure Cache for Redis emulation, BEAM-native, backed by the ELIXIR ECOSYSTEM
  cache: **Cachex** (the canonical Elixir cache, `{:cachex, "~> 4.0"}`).

  ## Scope revision (user direction, 2026-10-29)

  The original T-06 scope (RESP2 `:gen_tcp` wire listener emulating the Redis
  wire protocol) was DROPPED by user direction: "instead of redis, use elixir
  ecosystem". There is NO socket listener here — this module is a pure in-BEAM
  cache engine. The acceptance bar moved from wire-level redis-client
  compatibility to: ARM `Microsoft.Cache/redis` record parity + an
  Elixir-ecosystem cache API. Receipt:
  `docs/jira/v26.10.28/receipts/r15-t06-redis.md` (divergence table there).

  ## Public surface

    * `handle(command_list)` / `handle(account, command_list)` — evaluates a
      Redis-COMMAND-VOCABULARY list (e.g. `["SET", "k", "v"]`) against the
      Cachex-backed keyspace and returns the RESP2-ENCODED reply as
      `{:ok, resp}` | `{:error, resp}` (resp is a binary like `"+OK\\r\\n"`,
      `"$3\\r\\nfoo\\r\\n"`, `"-ERR ...\\r\\n"`). Retained per the revision so
      courts can assert command SEMANTICS byte-exactly and a future wire shim
      (if ever re-scoped) would be a pure byte pump. There is no socket.
    * `cache_start(account)` — starts (idempotently) the account's Cachex
      instance (first-caller-linked, the shadow-table law for processes).
    * `cache_child_spec(account)` — supervised child spec for the same
      instance (embedders/prewarm wiring).
    * `registry(account)` — ARM `Microsoft.Cache/Redis` record: id/name/type,
      `hostName: "127.0.0.1"`, Store-backed primaryKey/secondaryKey (stable
      across calls), and an `endpoints` map naming the LOCAL ACCESSOR
      (`Smalt.DataPlane.AzureCache` + account + cache name) instead of a
      wire connection string (honest divergence — see receipt).
    * `list_keys(account)` — the `az redis list-keys` face (primaryKey /
      secondaryKey only).

  ## Redis command vocabulary -> Cachex mapping

    AUTH (accept-any), HELLO (2; 3 refused), PING, ECHO, SELECT, QUIT,
    CLIENT SETNAME/SETINFO/GETNAME, CONFIG GET/SET (honest stubs) — no store.
    SET/GET/DEL/EXISTS -> `Cachex.put/get/del/exists?` on tagged string
    entries. EXPIRE/TTL -> `Cachex.expire/ttl` (millisecond TTLs). INCR/DECR
    -> `Cachex.incr/decr` (atomic). LPUSH/RPUSH/LRANGE, SADD/SMEMBERS,
    HSET/HGET/HGETALL -> the WHOLE structure is the Cachex VALUE
    (`{:azure_list, ..}` / `{:azure_set, %MapSet{}}` / `{:azure_hash, %{} }`);
    read-modify-write runs under `Cachex.transaction/4` row locking. KEYS ->
    `Cachex.keys/1` + `*`/`?` glob. SCAN -> single-bucket simple form
    (cursor 0, full page). INFO -> server section honestly reporting the
    Cachex/Elixir backing (`redis_version:smalt-cachex-<vsn>`, `os:beam`,
    `tcp_port:0` — no wire listener).

  ## Type tagging

  Every Cachex value written here is tagged `{:string, bin}`,
  `{:azure_list, [bin]}`, `{:azure_set, %MapSet{} ± binary members}`,
  `{:azure_hash, %{bin => bin}}` — WRONGTYPE is enforced by tag, exactly the
  Redis behavior.

  ## Non-goals (unchanged from the ticket)

  RESP3, clustering/replication verbs, Modules, PUB/SUB, and (per the
  revision) any wire protocol. Persistence: the account caches are in-memory
  Cachex ETS; the registry table is Store-backed. Restart persistence for the
  keyspace would ride the integrator's StoreTables/DetsMirror registration
  (receipt follow-up) — it is NOT part of the revised bar.
  """

  @default_account "default"
  @default_subscription "00000000-0000-0000-0000-000000000000"
  @registry_table :smalt_azure_cache
  @cache_prefix "smalt_azure_cache_"

  @wrongtype "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
  @not_integer "-ERR value is not an integer or out of range\r\n"

  # ===========================================================================
  # Cache lifecycle (Cachex instances, one per account)
  # ===========================================================================

  @doc "Default account used by `handle/1` (and prewarm wiring)."
  def default_account, do: @default_account

  @doc """
  The named Cachex instance for `account`. Accounts are validated
  (`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$`) before becoming atoms — the namespace
  is bounded by that charset + length cap (no unbounded atom creation).
  """
  def cache_name(account) when is_binary(account) do
    unless valid_account?(account) do
      raise ArgumentError,
            "Smalt.DataPlane.AzureCache: invalid account #{inspect(account)} " <>
              "(must match ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$)"
    end

    String.to_atom(@cache_prefix <> String.downcase(account))
  end

  @doc """
  Starts (idempotently) the account's Cachex instance and returns
  `{:ok, pid}`. First-caller-linked (the lazy shadow-process law — callers
  that need supervision embed `cache_child_spec/1` instead). The instance is
  booted with `transactions: true` so `Cachex.transaction/4` row locking is
  available to the structured-value read-modify-writes.
  """
  def cache_start(account) when is_binary(account) do
    name = cache_name(account)

    case Process.whereis(name) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case Cachex.start_link(name, transactions: true) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Supervised child spec for the account's Cachex instance."
  def cache_child_spec(account) when is_binary(account) do
    name = cache_name(account)

    %{
      id: {__MODULE__, :cache, name},
      start: {Cachex, :start_link, [name, [transactions: true]]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  # ===========================================================================
  # Command evaluation surface
  # ===========================================================================

  @doc "Evaluates `command_list` against the default account's keyspace."
  @spec handle([binary()]) :: {:ok, binary()} | {:error, binary()}
  def handle(command_list) when is_list(command_list) do
    handle(@default_account, command_list)
  end

  @doc """
  Evaluates a Redis-command-vocabulary `command_list` (all elements binaries,
  e.g. `["SET", "k", "v"]`) against `account`'s Cachex keyspace and returns
  the RESP2-encoded reply as `{:ok, resp} | {:error, resp}` (errors here are
  command-level errors like `-ERR`/`-WRONGTYPE`, never crashes).
  """
  @spec handle(binary(), [binary()]) :: {:ok, binary()} | {:error, binary()}
  def handle(account, command_list) when is_binary(account) and is_list(command_list) do
    cond do
      not valid_account?(account) ->
        resp_error("ERR invalid account #{inspect(account)}")

      not Enum.all?(command_list, &is_binary/1) ->
        resp_error("ERR command list must contain only binaries")

      true ->
        case cache_start(account) do
          {:ok, _pid} ->
            case command_list do
              [] -> resp_error("ERR empty command")
              [cmd | args] -> dispatch(account, cache_name(account), String.upcase(cmd), args)
            end

          {:error, reason} ->
            resp_error("ERR cache start failed: #{inspect(reason)}")
        end
    end
  end

  # -- Connection/handshake vocabulary (no store) -------------------------------

  defp dispatch(_account, _cache, "PING", []), do: resp_simple("PONG")
  defp dispatch(_account, _cache, "PING", [msg]), do: resp_bulk(msg)
  defp dispatch(_account, _cache, "ECHO", [msg]), do: resp_bulk(msg)

  # AUTH accepts ANY password (documented divergence: the registry keys are
  # advisory identity material until an enforcement flag exists — receipt).
  defp dispatch(_account, _cache, "AUTH", args) when length(args) in [1, 2],
    do: resp_simple("OK")

  defp dispatch(_account, _cache, "AUTH", _), do: wrong_arity("auth")
  defp dispatch(_account, _cache, "SELECT", [_db]), do: resp_simple("OK")
  defp dispatch(_account, _cache, "QUIT", []), do: resp_simple("OK")

  # HELLO: the wire-consumer law (receipt-gated pinion flip, 2026-10-29):
  # HELLO 3 is answered with the successful hello map, "proto" honest as "2" —
  # the wire emits RESP2 only and RESP3-speaking clients parse RESP2 fine.
  # This SUPERSEDES the v26.10.28 RESP2-only-refusal pinion; evidence:
  # consumer leg 3 log `redis_client_error: ERR protocol error` + byte-captured
  # first bytes `HELLO 3` (docs/jira/v26.10.29/receipts/r1-t01-redis-wire.md).
  defp dispatch(_account, _cache, "HELLO", []), do: hello_reply()
  defp dispatch(_account, _cache, "HELLO", ["2"]), do: hello_reply()
  defp dispatch(_account, _cache, "HELLO", ["3"]), do: hello_reply()

  defp dispatch(_account, _cache, "CLIENT", ["SETNAME" | _]), do: resp_simple("OK")
  defp dispatch(_account, _cache, "CLIENT", ["SETINFO" | _]), do: resp_simple("OK")
  defp dispatch(_account, _cache, "CLIENT", ["GETNAME"]), do: resp_bulk("")

  # node-redis 6.x sends `CLIENT MAINT_NOTIFICATIONS ON ...` as its final
  # connect-time command (witnessed byte-capture, v26.10.29 consumer court
  # r3): refusing it (-ERR) makes the client stall its handshake with no
  # fallback. Accept the negotiation; honest divergence: the notifications
  # are never emitted. KD-COVERS: see r1/r3 receipts.
  defp dispatch(_account, _cache, "CLIENT", ["MAINT_NOTIFICATIONS" | _]),
    do: resp_simple("OK")
  defp dispatch(_account, _cache, "CONFIG", ["GET" | _params]), do: resp_array([])
  defp dispatch(_account, _cache, "CONFIG", ["SET" | _]), do: resp_simple("OK")

  defp dispatch(account, _cache, "INFO", args) do
    section = case args do
      [s | _] -> String.downcase(s)
      [] -> "server"
    end

    resp_bulk(info_server(account, section))
  end

  # -- Strings ------------------------------------------------------------------

  defp dispatch(_account, cache, "SET", [k, v]) do
    case Cachex.put(cache, k, {:string, v}) do
      {:ok, true} -> resp_simple("OK")
      {:error, reason} -> resp_error("ERR set failed: #{inspect(reason)}")
    end
  end

  # SET with options — the consumer shapes seen on the wire (r3 court):
  #   * connect-redis session writes: `SET <sid> <sess> EX <secs>`
  #   * RedisKeyValueStore setIfAbsent: `SET <key> <val> NX PX <ms>`
  # Parses a bounded option tail (NX / XX / EX n / PX n) over the base put;
  # NX with an existing key answers the faithful RESP2 nil bulk. EX/PX
  # semantics match EXPIRE: wire seconds/millis -> Cachex milliseconds.
  defp dispatch(_account, cache, "SET", [k, v | opts]) when opts != [] do
    case parse_set_opts(opts, false, nil) do
      {:ok, nx?, millis} ->
        cond do
          nx? and Cachex.exists?(cache, k) == {:ok, true} ->
            resp_bulk(nil)

          true ->
            case Cachex.put(cache, k, {:string, v}, expire: millis) do
              {:ok, true} -> resp_simple("OK")
              {:error, reason} -> resp_error("ERR set failed: #{inspect(reason)}")
            end
        end

      :error ->
        {:error, @not_integer}
    end
  end

  # Bounded SET option-tail parser: NX | XX | EX <n> | PX <n>; last EX/PX wins.
  defp parse_set_opts([], nx, millis), do: {:ok, nx, millis}
  defp parse_set_opts(["NX" | rest], _nx, millis), do: parse_set_opts(rest, true, millis)
  defp parse_set_opts(["XX" | rest], nx, millis), do: parse_set_opts(rest, nx, millis)

  defp parse_set_opts(["EX", n | rest], nx, _millis) do
    case parse_int(n) do
      {:ok, s} -> parse_set_opts(rest, nx, s * 1000)
      :error -> :error
    end
  end

  defp parse_set_opts(["PX", n | rest], nx, _millis) do
    case parse_int(n) do
      {:ok, ms} -> parse_set_opts(rest, nx, ms)
      :error -> :error
    end
  end

  defp parse_set_opts(_, _, _), do: :error

  defp dispatch(_account, _cache, "SET", _), do: wrong_arity("set")

  defp dispatch(_account, cache, "GET", [k]) do
    case Cachex.get(cache, k) do
      {:ok, nil} -> resp_bulk(nil)
      {:ok, {:string, v}} -> resp_bulk(v)
      # Cachex.incr/4's native untagged integer (see incr_decr) renders as the
      # decimal string — Redis GET-after-INCR semantics.
      {:ok, n} when is_integer(n) -> resp_bulk(Integer.to_string(n))
      {:ok, _other} -> wrongtype()
      {:error, reason} -> resp_error("ERR get failed: #{inspect(reason)}")
    end
  end

  defp dispatch(_account, _cache, "GET", _), do: wrong_arity("get")

  defp dispatch(_account, cache, "DEL", keys) when keys != [] do
    count =
      Enum.count(keys, fn k ->
        match?({:ok, true}, Cachex.exists?(cache, k)) and match?({:ok, true}, Cachex.del(cache, k))
      end)

    resp_int(count)
  end

  defp dispatch(_account, _cache, "DEL", _), do: wrong_arity("del")

  defp dispatch(_account, cache, "EXISTS", keys) when keys != [] do
    count = Enum.count(keys, fn k -> match?({:ok, true}, Cachex.exists?(cache, k)) end)
    resp_int(count)
  end

  defp dispatch(_account, _cache, "EXISTS", _), do: wrong_arity("exists")

  # EXPIRE key seconds — Cachex.expire is millisecond; non-positive evicts
  # immediately (matches Redis: an expired-away key answers 1). Missing key
  # answers 0 (Cachex.expire -> {:ok, false}).
  defp dispatch(_account, cache, "EXPIRE", [k, seconds]) do
    case parse_int(seconds) do
      {:ok, s} ->
        case Cachex.expire(cache, k, s * 1000) do
          {:ok, true} -> resp_int(1)
          {:ok, false} -> resp_int(0)
          {:error, reason} -> resp_error("ERR expire failed: #{inspect(reason)}")
        end

      :error ->
        {:error, @not_integer}
    end
  end

  defp dispatch(_account, _cache, "EXPIRE", _), do: wrong_arity("expire")

  # TTL key — -2 missing / -1 no expiry / remaining seconds (faithful Redis
  # truncation: div of the remaining milliseconds).
  defp dispatch(_account, cache, "TTL", [k]) do
    case Cachex.exists?(cache, k) do
      {:ok, false} ->
        resp_int(-2)

      {:ok, true} ->
        case Cachex.ttl(cache, k) do
          {:ok, nil} -> resp_int(-1)
          {:ok, ms} -> resp_int(div(ms, 1000))
          {:error, reason} -> resp_error("ERR ttl failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        resp_error("ERR ttl failed: #{inspect(reason)}")
    end
  end

  defp dispatch(_account, _cache, "TTL", _), do: wrong_arity("ttl")

  # INCR/DECR — atomic via Cachex.incr/decr (amount ±1, :default 0 for a
  # missing key). A non-integer string value answers the exact Redis -ERR;
  # a structured (list/set/hash) entry answers WRONGTYPE.
  defp dispatch(_account, cache, "INCR", [k]), do: incr_decr(cache, k, 1)
  defp dispatch(_account, _cache, "INCR", _), do: wrong_arity("incr")
  defp dispatch(_account, cache, "DECR", [k]), do: incr_decr(cache, k, -1)
  defp dispatch(_account, _cache, "DECR", _), do: wrong_arity("decr")

  # -- Lists / sets / hashes (whole-structure Cachex values + row locking) ------

  defp dispatch(_account, cache, "LPUSH", [k | vals]) when vals != [],
    do: list_push(cache, k, vals, :left)

  defp dispatch(_account, _cache, "LPUSH", _), do: wrong_arity("lpush")

  defp dispatch(_account, cache, "RPUSH", [k | vals]) when vals != [],
    do: list_push(cache, k, vals, :right)

  defp dispatch(_account, _cache, "RPUSH", _), do: wrong_arity("rpush")

  defp dispatch(_account, cache, "LRANGE", [k, start, stop]) do
    with {:ok, s} <- parse_int(start),
         {:ok, e} <- parse_int(stop) do
      case Cachex.get(cache, k) do
        {:ok, nil} -> resp_array([])
        {:ok, {:azure_list, list}} -> resp_array(lrange(list, s, e))
        {:ok, _other} -> wrongtype()
        {:error, reason} -> resp_error("ERR lrange failed: #{inspect(reason)}")
      end
    else
      :error -> {:error, @not_integer}
    end
  end

  defp dispatch(_account, _cache, "LRANGE", _), do: wrong_arity("lrange")

  defp dispatch(_account, cache, "SADD", [k | members]) when members != [],
    do: set_add(cache, k, members)

  defp dispatch(_account, _cache, "SADD", _), do: wrong_arity("sadd")

  defp dispatch(_account, cache, "SMEMBERS", [k]) do
    case Cachex.get(cache, k) do
      {:ok, nil} -> resp_array([])
      {:ok, {:azure_set, set}} -> resp_array(Enum.sort(MapSet.to_list(set)))
      {:ok, _other} -> wrongtype()
      {:error, reason} -> resp_error("ERR smembers failed: #{inspect(reason)}")
    end
  end

  defp dispatch(_account, _cache, "SMEMBERS", _), do: wrong_arity("smembers")

  defp dispatch(_account, cache, "HSET", [k | field_vals]) do
    case field_vals |> Enum.chunk_every(2) |> pairs_or_incomplete() do
      {:ok, pairs} -> hash_set(cache, k, pairs)
      :incomplete -> wrong_arity("hset")
    end
  end

  defp dispatch(_account, _cache, "HSET", _), do: wrong_arity("hset")

  defp dispatch(_account, cache, "HGET", [k, field]) do
    case Cachex.get(cache, k) do
      {:ok, nil} -> resp_bulk(nil)
      {:ok, {:azure_hash, map}} -> resp_bulk(Map.get(map, field))
      {:ok, _other} -> wrongtype()
      {:error, reason} -> resp_error("ERR hget failed: #{inspect(reason)}")
    end
  end

  defp dispatch(_account, _cache, "HGET", _), do: wrong_arity("hget")

  defp dispatch(_account, cache, "HGETALL", [k]) do
    case Cachex.get(cache, k) do
      {:ok, nil} ->
        resp_array([])

      {:ok, {:azure_hash, map}} ->
        # Deterministic (field-sorted) emission — documented divergence:
        # real Redis order is unspecified anyway, sorted is court-stable.
        flat =
          map
          |> Enum.sort_by(fn {f, _v} -> f end)
          |> Enum.flat_map(fn {f, v} -> [f, v] end)

        resp_array(flat)

      {:ok, _other} ->
        wrongtype()

      {:error, reason} ->
        resp_error("ERR hgetall failed: #{inspect(reason)}")
    end
  end

  defp dispatch(_account, _cache, "HGETALL", _), do: wrong_arity("hgetall")

  # -- Keyspace enumeration ------------------------------------------------------

  defp dispatch(_account, cache, "KEYS", [pattern]) do
    case keys_matching(cache, pattern) do
      {:matched, found} -> resp_array(found)
      error -> error
    end
  end

  defp dispatch(_account, _cache, "KEYS", _), do: wrong_arity("keys")

  # SCAN cursor [MATCH pattern] [COUNT n] — single-bucket simple form: every
  # cursor is answered with the full matching page and cursor "0" back.
  defp dispatch(_account, cache, "SCAN", [cursor | opts]) when is_binary(cursor) do
    {pattern, _count} = parse_scan_opts(opts, nil, nil)

    case keys_matching(cache, pattern || "*") do
      {:matched, found} -> resp_array(["0" | found])
      error -> error
    end
  end

  defp dispatch(_account, _cache, "SCAN", _), do: wrong_arity("scan")

  # -- Unknown -------------------------------------------------------------------

  defp dispatch(_account, _cache, cmd, _args) do
    resp_error("ERR unknown command '#{cmd}'")
  end

  # ===========================================================================
  # ARM control-plane face: Microsoft.Cache/Redis records (Store-backed)
  # ===========================================================================

  @doc """
  Creates (idempotently) the ARM `Microsoft.Cache/Redis` record for `account`
  and returns `{:ok, record}`. Store-backed (`:smalt_azure_cache`, the lazy
  shadow-table law — `Smalt.Policy` precedent, heir to `:init`): the
  primaryKey/secondaryKey are generated once and STABLE across calls and
  processes. The record carries the ARM shape (`id`/`name`/`type`,
  `properties.hostName` = `"127.0.0.1"`, provisioningState, sku) PLUS the
  honest smalt divergence: `properties.endpoints` names the local BEAM
  accessor (`Smalt.DataPlane.AzureCache` + account + cache name) instead of a
  wire connection string, `port`/`sslPort` are 0 (no wire listener), and
  `wireListener` says so.
  """
  @spec registry(binary(), keyword()) :: {:ok, map()}
  def registry(account, opts \\ []) when is_binary(account) do
    unless valid_account?(account) do
      raise ArgumentError,
            "Smalt.DataPlane.AzureCache.registry/2: invalid account #{inspect(account)}"
    end

    ensure_registry_table()
    row_key = String.downcase(account)

    case Smalt.Store.get(@registry_table, row_key) do
      {:ok, record} ->
        {:ok, record}

      :error ->
        primary = access_key()
        secondary = access_key()

        subscription_id = Keyword.get(opts, :subscription_id, @default_subscription)
        resource_group = Keyword.get(opts, :resource_group, "rg-#{row_key}")

        record = %{
          "id" =>
            "/subscriptions/#{subscription_id}/resourceGroups/#{resource_group}" <>
              "/providers/Microsoft.Cache/Redis/#{account}",
          "name" => account,
          "type" => "Microsoft.Cache/Redis",
          "location" => Keyword.get(opts, :location, "beam-local"),
          "properties" => %{
            "provisioningState" => "Succeeded",
            "hostName" => "127.0.0.1",
            "port" => 0,
            "sslPort" => 0,
            "redisVersion" => "smalt-cachex-#{cachex_version()}",
            "enableNonSslPort" => true,
            "minimumTlsVersion" => "1.2",
            "sku" => %{"name" => "Basic", "family" => "C", "capacity" => 0},
            "primaryKey" => primary,
            "secondaryKey" => secondary,
            "accessKeys" => %{"primaryKey" => primary, "secondaryKey" => secondary},
            "endpoints" => endpoints(account),
            "wireListener" => "none"
          }
        }

        case Smalt.Store.insert_new(@registry_table, row_key, record) do
          :ok ->
            {:ok, record}

          {:error, :exists} ->
            {:ok, stored} = Smalt.Store.get(@registry_table, row_key)
            {:ok, stored}
        end
    end
  end

  @doc "The `az redis list-keys` face: `{:ok, %{\"primaryKey\" => .., \"secondaryKey\" => ..}}`."
  @spec list_keys(binary()) :: {:ok, map()}
  def list_keys(account) when is_binary(account) do
    {:ok, record} = registry(account)
    props = record["properties"]

    {:ok, %{"primaryKey" => props["primaryKey"], "secondaryKey" => props["secondaryKey"]}}
  end

  @doc """
  The local access endpoints map (the honest replacement for a wire
  connection string): names the module + account + Cachex instance an
  Elixir caller binds to.
  """
  def endpoints(account) when is_binary(account) do
    %{
      # inspect/1 renders the module WITHOUT the "Elixir." atom prefix — the
      # court pins the bare module name.
      "moduleName" => inspect(__MODULE__),
      "account" => account,
      "cacheName" => Atom.to_string(cache_name(account)),
      "transport" => "beam-local"
    }
  end

  # ===========================================================================
  # Internals: structure read-modify-writes (Cachex.transaction row locking)
  # ===========================================================================

  defp incr_decr(cache, k, dir) do
    case Cachex.get(cache, k) do
      {:ok, nil} ->
        do_incr(cache, k, dir)

      {:ok, {:string, v}} ->
        case parse_int(v) do
          {:ok, _} -> do_incr(cache, k, dir)
          :error -> {:error, @not_integer}
        end

      # SHIM-COURT-ADJACENT (L3, v26.10.29): Cachex.incr/4 stores the counter
      # as a BARE untagged integer — a second INCR/DECR must see it as numeric,
      # never as a structured (WRONGTYPE) entry. GET renders it too (Redis:
      # GET after INCR answers the decimal string).
      {:ok, n} when is_integer(n) ->
        do_incr(cache, k, dir)

      {:ok, _structured} ->
        wrongtype()

      {:error, reason} ->
        resp_error("ERR incr failed: #{inspect(reason)}")
    end
  end

  defp do_incr(cache, k, dir) do
    case Cachex.incr(cache, k, dir, default: 0) do
      {:ok, n} -> resp_int(n)
      {:error, reason} -> resp_error("ERR incr failed: #{inspect(reason)}")
    end
  end

  defp list_push(cache, k, vals, side) do
    case Cachex.transaction(cache, [k], fn worker ->
           case Cachex.get(worker, k) do
             {:ok, nil} ->
               list = apply_push([], vals, side)
               Cachex.put(worker, k, {:azure_list, list})
               {:ok, length(list)}

             {:ok, {:azure_list, list}} ->
               list = apply_push(list, vals, side)
               Cachex.put(worker, k, {:azure_list, list})
               {:ok, length(list)}

             {:ok, _other} ->
               :wrongtype

             {:error, reason} ->
               {:error, reason}
           end
         end) do
      {:ok, {:ok, len}} -> resp_int(len)
      {:ok, :wrongtype} -> wrongtype()
      {:ok, {:error, reason}} -> resp_error("ERR lpush failed: #{inspect(reason)}")
      {:error, reason} -> resp_error("ERR transaction failed: #{inspect(reason)}")
    end
  end

  defp apply_push(list, vals, :left), do: Enum.reduce(vals, list, fn v, acc -> [v | acc] end)
  defp apply_push(list, vals, :right), do: list ++ vals

  defp set_add(cache, k, members) do
    case Cachex.transaction(cache, [k], fn worker ->
           case Cachex.get(worker, k) do
             {:ok, nil} ->
               set = MapSet.new(members)
               Cachex.put(worker, k, {:azure_set, set})
               {:ok, MapSet.size(set)}

             {:ok, {:azure_set, set}} ->
               new = Enum.count(members, fn m -> not MapSet.member?(set, m) end)
               Cachex.put(worker, k, {:azure_set, MapSet.union(set, MapSet.new(members))})
               {:ok, new}

             {:ok, _other} ->
               :wrongtype

             {:error, reason} ->
               {:error, reason}
           end
         end) do
      {:ok, {:ok, n}} -> resp_int(n)
      {:ok, :wrongtype} -> wrongtype()
      {:ok, {:error, reason}} -> resp_error("ERR sadd failed: #{inspect(reason)}")
      {:error, reason} -> resp_error("ERR transaction failed: #{inspect(reason)}")
    end
  end

  defp hash_set(cache, k, pairs) do
    case Cachex.transaction(cache, [k], fn worker ->
           case Cachex.get(worker, k) do
             {:ok, nil} ->
               map = Map.new(pairs)
               Cachex.put(worker, k, {:azure_hash, map})
               {:ok, map_size(map)}

             {:ok, {:azure_hash, map}} ->
               new = Enum.count(pairs, fn {f, _} -> not Map.has_key?(map, f) end)
               Cachex.put(worker, k, {:azure_hash, Map.merge(map, Map.new(pairs))})
               {:ok, new}

             {:ok, _other} ->
               :wrongtype

             {:error, reason} ->
               {:error, reason}
           end
         end) do
      {:ok, {:ok, n}} -> resp_int(n)
      {:ok, :wrongtype} -> wrongtype()
      {:ok, {:error, reason}} -> resp_error("ERR hset failed: #{inspect(reason)}")
      {:error, reason} -> resp_error("ERR transaction failed: #{inspect(reason)}")
    end
  end

  # ===========================================================================
  # Internals: keyspace enumeration (KEYS/SCAN)
  # ===========================================================================

  defp keys_matching(cache, pattern) do
    case Cachex.keys(cache) do
      {:ok, keys} ->
        re = glob_regex(pattern)

        {:matched,
         keys
         |> Enum.filter(&is_binary/1)
         |> Enum.filter(&Regex.match?(re, &1))
         |> Enum.sort()}

      {:error, reason} ->
        resp_error("ERR keys failed: #{inspect(reason)}")
    end
  end

  # Glob with `*` and `?` only (the ticket's simple form); everything else is
  # regex-escaped.
  defp glob_regex(pattern) do
    source =
      pattern
      |> String.codepoints()
      |> Enum.map_join("", fn
        "*" -> ".*"
        "?" -> "."
        c -> Regex.escape(c)
      end)

    Regex.compile!("^" <> source <> "$")
  end

  defp parse_scan_opts(["MATCH", p | rest], _match, count), do: parse_scan_opts(rest, p, count)
  defp parse_scan_opts(["COUNT", _n | rest], match, _count), do: parse_scan_opts(rest, match, nil)
  defp parse_scan_opts([_unknown | rest], match, count), do: parse_scan_opts(rest, match, count)
  defp parse_scan_opts([], match, count), do: {match, count}

  # ===========================================================================
  # Internals: RESP2 encoding (kept so courts assert protocol semantics and a
  # future wire shim would be a pure byte pump)
  # ===========================================================================

  defp resp_simple(s), do: {:ok, "+#{s}\r\n"}
  defp resp_int(i), do: {:ok, ":#{i}\r\n"}
  defp resp_error(msg), do: {:error, "-#{msg}\r\n"}

  defp resp_bulk(nil), do: {:ok, "$-1\r\n"}

  defp resp_bulk(s) when is_binary(s), do: {:ok, "$#{byte_size(s)}\r\n#{s}\r\n"}

  defp resp_array(items) when is_list(items) do
    body = Enum.map(items, &bulk_bytes/1)
    {:ok, "*#{length(items)}\r\n" <> IO.iodata_to_binary(body)}
  end

  defp bulk_bytes(nil), do: "$-1\r\n"
  defp bulk_bytes(v) when is_binary(v), do: "$#{byte_size(v)}\r\n#{v}\r\n"

  defp wrongtype, do: {:error, @wrongtype}

  defp wrong_arity(cmd), do: resp_error("ERR wrong number of arguments for '#{cmd}' command")

  defp hello_reply do
    resp_array([
      "server",
      "redis",
      "version",
      "smalt-cachex-#{cachex_version()}",
      "proto",
      "2",
      "id",
      run_id(),
      "mode",
      "standalone"
    ])
  end

  # INFO server section — shaped like Azure Cache for Redis (redis_version /
  # os / tcp_port / run_id) but HONEST about the smalt backing: the Cachex
  # version renders in redis_version, os is the BEAM, tcp_port is 0 (there is
  # no wire listener), and azure_* extension rows carry the divergence.
  defp info_server(account, _section) do
    [
      "# Server",
      "redis_version:smalt-cachex-#{cachex_version()}",
      "redis_mode:standalone",
      "os:beam",
      "tcp_port:0",
      "run_id:#{run_id()}",
      "uptime_in_seconds:#{div(System.system_time(:millisecond) - boot_ms(), 1000)}",
      "azure_backing:cachex-#{cachex_version()}",
      "azure_cache_module:#{inspect(__MODULE__)}",
      "azure_account:#{account}",
      "azure_transport:beam-local",
      "azure_wire_listener:none"
    ]
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp cachex_version do
    case Application.spec(:cachex, :vsn) do
      nil -> "unknown"
      vsn -> IO.iodata_to_binary(vsn)
    end
  end

  defp run_id do
    get_or_put_persistent({__MODULE__, :run_id}, fn ->
      :crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)
    end)
  end

  defp boot_ms do
    get_or_put_persistent({__MODULE__, :boot_ms}, fn -> System.system_time(:millisecond) end)
  end

  defp get_or_put_persistent(key, gen) do
    case :persistent_term.get(key, nil) do
      nil ->
        value = gen.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  # ===========================================================================
  # Internals: registry table (lazy shadow-table law, Smalt.Policy precedent)
  # ===========================================================================

  # The `:smalt_azure_cache` table is NOT in the generated Store registry
  # (lib/smalt/store_tables.ex is generator-owned): it is lazily created here
  # with an heir to :init so it outlives its first creator (the wire witness
  # of the PW lane — without the heir the table dies with the creating
  # request process). Integrator follow-up (receipt): register it via the
  # `mix smalt.gen` StoreTables regeneration to gain the DETS mirror lane.
  defp ensure_registry_table do
    if :ets.info(@registry_table) == :undefined do
      try do
        :ets.new(@registry_table, [
          :named_table,
          :public,
          :ordered_set,
          {:read_concurrency, true},
          {:write_concurrency, true},
          {:heir, Process.whereis(:init), []}
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp access_key, do: :crypto.strong_rand_bytes(32) |> Base.encode64()

  # ===========================================================================
  # Internals: small parse helpers
  # ===========================================================================

  defp valid_account?(account) do
    is_binary(account) and Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/, account)
  end

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp pairs_or_incomplete(pairs) do
    if Enum.any?(pairs, fn p -> length(p) != 2 end) do
      :incomplete
    else
      {:ok, Enum.map(pairs, fn [f, v] -> {f, v} end)}
    end
  end

  # Redis LRANGE index semantics: negatives are from the end, both ends clamp.
  defp lrange(list, start, stop) do
    len = length(list)

    s = if start < 0, do: max(len + start, 0), else: min(start, len)
    e = if stop < 0, do: len + stop, else: min(stop, len - 1)

    if s > e or s >= len, do: [], else: Enum.slice(list, s, e - s + 1)
  end
end
