# T-06 — Azure Cache for Redis: RESP2 data plane

- status: CODE-COMPLETE (2026-10-29): r15, awaiting integration run (revised: Elixir-ecosystem Cachex backing; RESP wire listener dropped per user direction)
- window: v26.10.28 · maps-to: Topaz v1.11 "Redis Cache — RESP2 data plane · TLS listener · GetConnectionStrings" · verdict-at-open: **GAP**
- size: **XL** · depends-on: — · parity-leg: redis suite (node-redis / redis-cli probes)

## current state (evidence)

No Redis surface: none of the 16 `lib/smalt/data_plane/` modules speaks
RESP (`parity/COVERAGE_VS_TOPAZ.md` matrix — absent row).

## scope

1. ARM `Microsoft.Cache/redis` control plane: create/update/delete/list,
   `regenerateKey`, and the `listKeys` + `GetConnectionStrings` action
   returning the local host:port and generated keys.
2. A RESP2 TCP listener (new listener class alongside the AMQP tier, not
   Bandit/HTTP): the core command set real clients touch first —
   `AUTH/HELLO(no-args)/PING/HELLO(3→2 fallback)`, `SET/GET/DEL/EXISTS`,
   `EXPIRE/TTL`, `INCR/DECR`, `LPUSH/RPUSH/LRANGE`, `SADD/SMEMBERS`,
   `HSET/HGET/HGETALL`, `SUBSCRIBE/PUBLISH` (best-effort), `KEYS/SCAN`,
   `INFO` (server section populated like real Azure's).
3. Persistence through the Store (DETS mirror) so restarts keep keys.
4. TLS listener: defer to a sub-ticket (flagged in the map; smalt's TLS
   posture is the twin-listener pattern).

## non-goals

- RESP3 protocol (HELLO 3 answers `-ERR` like real Azure's RESP2-only
  offering), clustering/replication verbs, Modules.

## Definition of Done — the Azure developer's view

You create a cache with `az redis create` against smalt, run
`az redis list-keys`, and paste the returned `127.0.0.1:<port>` +
`primaryKey` straight into your app's `REDIS_CONNECTIONSTRING` — your
existing node-redis / StackExchange.Redis / redis-cli client connects with
`AUTH`, and `SET`/`GET` round-trips, TTLs expire, counters increment, and a
restart of the substrate still finds your keys. `redis-cli INFO` shows a
server section shaped like Azure Cache for Redis. No code change in your
app beyond the connection string.

## receipts required

RESP2 transcript court (real client session recorded); restart-persistence
receipt; ARM listKeys ↔ AUTH integration receipt.
