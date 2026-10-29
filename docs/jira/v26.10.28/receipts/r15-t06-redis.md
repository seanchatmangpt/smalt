# r15 — T-06 (REVISED): Azure Cache for Redis emulation on Cachex; RESP wire listener DROPPED

- window: v26.10.28 · ticket: `tickets/T06-redis-resp2-data-plane.md` · date: 2026-10-29
- tier: beam (`test/integration/azure_cache_test.exs`)

## scope revision (user direction, 2026-10-29)

The user revised T-06 mid-lane: "instead of redis, use elixir ecosystem".
Consequences, applied here:

1. The XL RESP2 `:gen_tcp` wire-listener leg is DROPPED — no socket, no RESP
   framing, no `Smalt.DataPlane.RedisListener` (never landed; nothing to
   delete). The wire-level redis-client compatibility bar (`node-redis` /
   StackExchange.Redis / `redis-cli` transcripts) is NO LONGER the DoD.
2. The cache engine is `Smalt.DataPlane.AzureCache`, backed by **Cachex**
   (the canonical Elixir cache). Redis command SEMANTICS map onto Cachex
   calls; the `handle(command_list)` surface is retained so courts can assert
   command semantics byte-exactly (RESP2-encoded replies) and a future wire
   shim, if ever re-scoped, would be a pure byte pump.
3. The ARM `Microsoft.Cache/redis` control-plane face survives
   (`registry/1,2`, `list_keys/1`) with an HONEST endpoints map naming the
   local BEAM accessor instead of a wire connection string (divergence table
   below).

## what landed

1. **`lib/smalt/data_plane/azure_cache.ex`** — the engine:
   `handle/1` / `handle/2` (account-scoped) evaluating the Redis command
   vocabulary against a per-account named Cachex instance; `cache_start/1`
   (idempotent first-caller-linked start), `cache_child_spec/1` (supervised
   embedding), `cache_name/1`; `registry/1,2` + `list_keys/1` + `endpoints/1`
   (ARM records, Store-backed in the lazy shadow table `:smalt_azure_cache`
   — `Smalt.Policy` precedent, heir to `:init`, keys stable across calls).
2. **`test/integration/azure_cache_test.exs`** — the direct court (below).
3. This receipt (filename kept as `r15-t06-redis.md` for traceability with
   the ticket it revises).

## Cachex dependency — EXACT patch (integrator applies; engine is RUNTIME-dead until then)

The engine only makes plain remote calls (`Cachex.put/4` ...), so it
COMPILES without the dep; every code path fails at runtime
(`UndefinedFunctionError`) and this court fails until the dep lands:

```diff
--- a/mix.exs
+++ b/mix.exs
@@
   defp deps do
     [
+      {:cachex, "~> 4.0"},
       ...
     ]
   end
```

then `mix deps.get` (API verified against Cachex 4.1.1 docs on 2026-10-28:
`Cachex.start_link(name, opts)`; `put/4` TTL option is `:expire`
milliseconds; `get` miss -> `{:ok, nil}`; `exists?/expire` -> `{:ok, boolean}`
(false when missing); `ttl` -> `{:ok, ms | nil}`; `incr(cache, key, amount,
default: 0)`; `transaction(cache, keys, fun)` row locking).

## Redis command vocabulary -> Cachex mapping

| Redis command | Cachex backing |
|---|---|
| SET k v | `Cachex.put(cache, k, {:string, v})` |
| GET k | `Cachex.get(cache, k)` (miss `{:ok, nil}` -> `$-1`) |
| DEL / EXISTS | `Cachex.exists?` + `Cachex.del` |
| EXPIRE k s | `Cachex.expire(cache, k, s * 1000)` (non-positive evicts, like Redis) |
| TTL k | `Cachex.exists?` (-2) + `Cachex.ttl` (`nil` -> -1, else `div(ms, 1000)`) |
| INCR / DECR | `Cachex.incr/decr(cache, k, ±1, default: 0)` (atomic) |
| LPUSH/RPUSH/LRANGE | whole list is the value `{:azure_list, ..}`; RMW under `Cachex.transaction/4` row lock |
| SADD/SMEMBERS | whole set is the value `{:azure_set, %MapSet{}}`; RMW under transaction |
| HSET/HGET/HGETALL | whole hash is the value `{:azure_hash, %{} }}`; RMW under transaction |
| KEYS pat | `Cachex.keys/1` + `*`/`?` glob regex, sorted output |
| SCAN cur [MATCH m] [COUNT n] | single-bucket simple form: full page, cursor `"0"` |
| INFO [server] | rendered server section, honest backing (below) |
| AUTH (any password), HELLO (2; 3 -> `-NOPROTO`), PING, ECHO, SELECT, QUIT, CLIENT SETNAME/SETINFO/GETNAME, CONFIG GET/SET stubs | no store (handshake vocabulary real clients touch first) |

WRONGTYPE is enforced by the entry tag (`{:string,_}` vs
`{:azure_list,_}`/`{:azure_set,_}`/`{:azure_hash,_}`) — exactly the Redis
behavior.

INFO server section (shaped like Azure Cache for Redis, honest about the
backing): `redis_version:smalt-cachex-<cachex vsn>`, `os:beam`,
`tcp_port:0`, `run_id:<per-boot hex>`, plus `azure_backing`/`azure_account`/
`azure_wire_listener:none` extension rows.

## honest divergence table (post-revision DoD bar: ARM parity + Elixir cache API)

| real Azure Cache for Redis | smalt `AzureCache` | why |
|---|---|---|
| RESP2 wire endpoint (`host:port`, `redis-cli`/node-redis/StackExchange connect) | NO wire listener (`tcp_port:0`, `wireListener:none`) | user direction 2026-10-29: elixir ecosystem, wire emulation dropped |
| `listKeys` -> connection string `host:port,password=..,ssl=..` | `registry()` record carries primaryKey/secondaryKey + `endpoints` map `%{"moduleName" => "Smalt.DataPlane.AzureCache", "account" => .., "cacheName" => .., "transport" => "beam-local"}` | an Elixir caller binds the named Cachex instance; a password has no wire to gate |
| keys gate the wire (AUTH) | AUTH accepts ANY password; registry keys are advisory identity material | no wire -> nothing to authenticate (optional enforcement flag = follow-up if a consumer emerges) |
| restart keeps keys (AOF/replication) | in-memory Cachex ETS; registry records in `:smalt_azure_cache` (ETS, heir-to-`:init`) | restart persistence was the OLD wire-era bar; integrator follow-up: register `:smalt_azure_cache` via the `mix smalt.gen` StoreTables regeneration to gain the DetsMirror lane |
| HGETALL/KEYS order unspecified | deterministic (field-sorted / key-sorted) emission | court-stability; real-Redis order is unspecified anyway |
| RESP3 / clustering / Modules | out of scope (unchanged ticket non-goals) | — |

## court (NOT RUN — integration run pending)

`test/integration/azure_cache_test.exs` calls the engine DIRECTLY (no
socket), one unique account per test: SET/GET round-trip + DEL/EXISTS;
INCR/DECR (atomicity + non-integer refusal); EXPIRE/TTL semantics (1..5
window, -2/-1/0 faces); LPUSH/RPUSH/LRANGE order; SADD/SMEMBERS;
HSET/HGET/HGETALL; WRONGTYPE both directions; KEYS `*`/`?` globs; SCAN
cursor-0 simple form (+MATCH); INFO server section (`redis_version:smalt-
cachex-`, `os:beam`, `tcp_port:0`, `run_id:`); HELLO proto-2 + HELLO 3
`-NOPROTO`; AUTH accept-any; `cache_start` idempotence +
`cache_child_spec` shape; `registry/1` ARM record shape + Store-backed key
stability + `list_keys` face. The court carries a minimal in-file RESP2
decoder for assertions.

## optional application.ex wiring (opt-in cache prewarm; default byte-identical)

There is NO listener to wire. If a boot-time prewarm of specific account
caches is wanted (supervised, not first-caller-linked), the integrator may
apply:

```diff
--- a/lib/smalt/application.ex
+++ b/lib/smalt/application.ex
@@
     children =
       plane_children() ++
         [
           Smalt.Apim,
           Smalt.Telemetry.RollingCounters,
           Smalt.Monitor.Metrics
-        ] ++ mcp_tail ++ virtual_hw_child() ++ journal_sink_child() ++ cluster_child()
+        ] ++ mcp_tail ++ virtual_hw_child() ++ journal_sink_child() ++ cluster_child() ++
+          azure_cache_children()
@@
   defp cluster_child do
     if Application.get_env(:smalt, :cluster, []) |> Keyword.get(:enabled, false) do
       [Smalt.Cluster]
     else
       []
     end
   end
+
+  # T-06 (revised): opt-in Azure Cache prewarm — config :smalt,
+  # :azure_cache_accounts, ["acct1", ...]. Default [] boots byte-identical;
+  # accounts not prewarmed start lazily (first-caller-linked) on first command.
+  defp azure_cache_children do
+    :smalt
+    |> Application.get_env(:azure_cache_accounts, [])
+    |> Enum.map(&Smalt.DataPlane.AzureCache.cache_child_spec/1)
+  end
```

MANDATORY regardless of wiring: the mix.exs Cachex dep patch above.

## DoD mapping (revised)

Old bar (wire-era, DROPPED): `az redis create` + `az redis list-keys` +
paste connection string into node-redis/StackExchange; wire commands work;
`redis-cli INFO`.

Revised bar (this lane): an Elixir consumer starts/prewarms the account
cache (`cache_child_spec/1` or lazy `cache_start/1`), reads/writes through
`Smalt.DataPlane.AzureCache.handle/2` (or the Cachex instance directly via
`cache_name/1`), and the ARM face (`registry/1`, `list_keys/1`) returns the
`Microsoft.Cache/Redis` record with stable Store-backed primary/secondary
keys and the honest `endpoints` map. `INFO` reports the Cachex/Elixir
backing truthfully. Every divergence is disclosed in the table above, not
masked.

## follow-ups for the integrator (non-blocking)

1. Apply the mix.exs dep patch + `mix deps.get`, run the court.
2. Optional StoreTables regeneration to persist `:smalt_azure_cache` through
   the DetsMirror lane (restart-persistence receipt, old ticket scope item 3).
3. Optional ARM gateway rows (`Microsoft.Cache/redis` PUT/GET/list/delete,
   `regenerateKey`, `listKeys` action) riding `registry/1`/`list_keys/1` —
   the router is outside this lane's file ownership.
