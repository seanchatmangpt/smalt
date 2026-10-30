# r1-t01-redis-wire

**Lane**: T01 — Redis RESP2 wire listener
**Standing**: ALIVE
**Date**: 2026-10-29

## What landed

The RESP2 byte-pump TCP listener over `Smalt.DataPlane.AzureCache.handle/2`
(framing only — every command is evaluated by the same engine the in-BEAM
callers use; this layer owns sockets, framing and account selection).

Files (all within lane contract):

- `lib/smalt/data_plane/redis_wire.ex` (new) — three modules:
  - `Smalt.DataPlane.RedisWire` (facade supervisor; IntegrationSupervisor
    child, non-deferred per the `broker_children/0` precedent): owns the
    bind — the listen socket is opened in `init/1`, so a bind failure is
    CONTAINED: the listener child is skipped, the facade and the app boot
    (the AmqpBroker containment contract). Port:
    `config :smalt, :redis_port` default 6380, per-start override via
    `opts[:port]`. Bind IP rides the `Smalt.Config.bind_ip()` law
    (nil/"loopback" → loopback; binary → `:inet.parse_address` fail-closed
    raise; tuple → as configured). Also exposes
    `RedisWire.ensure_cache/1`: account Cachex instances started under the
    wire conn supervisor so a dying conn never takes its keyspace with it
    (the engine's `cache_start/1` is first-caller-linked — a conn must never
    be the first caller; witnessed as per-connection keyspaces in the court).
    `ensure_cache` is deferred out of conn `init/1` to a queued
    `:ensure_default_cache` message: calling `DynamicSupervisor.start_child`
    on the same supervisor from inside a child's init self-deadlocks
    (witnessed).
  - `Smalt.DataPlane.RedisWire.Listener` (accept loop, the
    `Smalt.Amqp.Listener` pattern: bounded accept + backoff). The registered
    name is a start arg — courts bind PRIVATE unnamed listeners on port 0
    (never the app-env default 6380).
  - `Smalt.DataPlane.RedisWire.Conn`: buffered framing (multibulk `*N` +
    `$len` bulks — including the `$` header prefix stripped before
    `Integer.parse`, the witnessed protocol-error bug — plus inline
    commands), bounded recv buffer (64 KiB) and command ceiling (64 MiB);
    `QUIT` → `+OK` + close; unrecoverable framing error →
    `-ERR protocol error` + close; AUTH 2-arg with a structurally valid
    first arg selects that account's keyspace for the connection (engine
    accepts any AUTH; the wire layer pins the keyspace).
  - `Listener.handoff` performs the `:gen_tcp.controlling_process` ownership
    handoff to the conn — without it the conn's exit never closes the client
    socket (witnessed: the protocol-error court saw no close for 5 s).
- `lib/smalt/plane/integration_supervisor.ex` — the one attach point:
  `children = ... ++ redis_wire_children()` appending
  `[{Smalt.DataPlane.RedisWire, []}]`.
- `test/integration/redis_wire_test.exs` (new) — Chicago court: a real
  listener on a PRIVATE port (port 0, unnamed) and a real `:gen_tcp` client;
  byte-exact RESP2 asserts (a protocol-framing client reader, no fixed
  sleeps): PING, SET/GET (binary-safe payloads), DEL/EXISTS, EXPIRE/TTL,
  INCR (fresh/repeated/GET-after/non-integer -ERR), HSET/HGET/HGETALL,
  LPUSH/LRANGE, SADD/SMEMBERS, KEYS, unknown-command -ERR, WRONGTYPE, AUTH
  keyspace selection + QUIT close, split-frame reassembly + protocol-error
  -ERR-then-close. Teardown: the test supervisor is linked to the ExUnit test
  process — its `:shutdown` exit IS the teardown (an explicit
  `Supervisor.stop` in `on_exit` races that kill and fails the court).

## Verification (real output, this session)

```
$ cd /Users/sac/smalt && export PATH="$HOME/.asdf/shims:$PATH" \
  && MIX_BUILD_ROOT=_build-t01 mix test test/integration/redis_wire_test.exs
Finished in 0.1 seconds (0.00s async, 0.1s sync)
Result: 13 passed
EXIT=0

$ MIX_BUILD_ROOT=_build-t01 mix test test/integration/redis_wire_test.exs \
    test/integration/azure_cache_test.exs
Finished in 0.4 seconds (0.00s async, 0.4s sync)
Result: 28 passed
EXIT=0
```

Compile: `MIX_BUILD_ROOT=_build-t01 mix compile --warnings-as-errors`
fails on PRE-EXISTING warnings in deps/other-lane files (ggen_igniter,
ash_r2rml, erl src, network schemas, EgressRouter, canonical_router) —
grep for `redis_wire|azure_cache|integration_supervisor` in the warning
stream returns ZERO hits (exit 1): this lane's files are warning-free.

## HELLO flip addendum (receipt-gated pinion flip, 2026-10-29)

Coordinator addendum: T03's consumer court proved the wire leg blocked on
HELLO negotiation — the pinned redis@6.3.0 npm client sends `HELLO 3` as its
first bytes and has no RESP2 fallback (retries forever on -ERR NOPROTO).
Evidence line: consumer leg 3 log `redis_client_error: ERR protocol error` +
byte-captured first bytes `HELLO 3`.

Change: `lib/smalt/data_plane/azure_cache.ex` — the `HELLO, ["3"]` clause
flipped from `-ERR NOPROTO ...` to the successful `hello_reply()` map with
"proto" honest as "2" (the wire emits RESP2 only; RESP3-speaking clients
parse RESP2 fine). This SUPERSEDES the v26.10.28 RESP2-only-refusal pinion
for the wire-consumer case.

Court update: `test/integration/azure_cache_test.exs` — the
"REFUSES HELLO 3" pin now asserts HELLO 3 answers the SAME map with
proto=2, comment citing this receipt.

Verification (real output, this session):

```
$ MIX_BUILD_ROOT=_build-t01 mix test test/integration/redis_wire_test.exs \
    test/integration/azure_cache_test.exs
Finished in 0.4 seconds (0.00s async, 0.4s sync)
Result: 28 passed
EXIT=0
```

## Falsifier status

- Court falsifier (wire semantics byte-exact through a real socket): RAN,
  13/13 PASS.
- HELLO flip falsifier (HELLO 3 answers the map, proto=2): RAN, PASS (both
  courts, 28/28).

## Follow-ups (not this lane's files)

1. Honesty flip in `AzureCache.registry/2`: the `tcp_port:0` /
   `wireListener:"none"` rows no longer hold. Pure functions are exposed in
   `redis_wire.ex` (`RedisWire.configured_port/0`, `RedisWire.honesty_rows/0`)
   for AzureCache to call — a one-line flip gated on coordinator ownership
   (azure_cache.ex ownership was granted ONLY for the HELLO clause flip).
2. The `:smalt_azure_cache` registry table remains lazy/heir-created
   (pre-existing); StoreTables regeneration is the integrator's item.

---

## Addendum — FINISH-WIRE lane, 2026-10-29 (RESP3 handshake + pipelining landed)

Standing: PARTIAL_ALIVE at receipt time — the redis wire surface is green
end-to-end; the court's SAML leg is blocked on a defect in a file this lane
does not own (`saml_idp.ex`, see r3 addendum).

### Landed in this addendum

1. RESP3 HELLO clause-order fix (`redis_wire.ex` Conn): the generic
   `execute/2` catch-all preceded the `["HELLO","3"]` clause, so HELLO 3 was
   routed to AzureCache's RESP2 `hello_reply()` (`*10` array, proto=2) — the
   exact desync class the court's fake-server bisect pinned ("Unknown RESP
   type 111 'o'"). The RESP3 clause now precedes the catch-all; `resp3_hello/0`
   answers `%5` map with `proto` as RESP3 integer `:3`.
2. PIPELINE LAW (`redis_wire.ex` Conn.feed): `feed/1` previously executed ONE
   command per `recv` cycle; node-redis 6.3 pipelines `HELLO` + 3x `CLIENT`
   in one TCP segment, so the buffer-parked remainder never drained and the
   client stalled ("Socket closed unexpectedly"). `feed` now loops until the
   buffer holds no complete command. Byte evidence: logging-TCP-proxy capture
   showing the client send one 5-command segment and close after receiving
   only the `%5` reply.
3. `SET` option tail (`azure_cache.ex`): `SET k v EX <s>` / `PX <ms>` /
   `NX PX <ms>` / `XX` now parse (connect-redis 10.0.0 session writes and
   RedisKeyValueStore `setIfAbsent`; api log falsifier: `ERR wrong number of
   arguments for 'set' command` on `/api/sso/start` → 500). NX on an existing
   key answers the faithful nil bulk; TTLs land as real Cachex `expire:`
   (note: `Cachex.put/4` option is `expire:`, NOT `ttl:` — probed).
4. Wire-court pins added: HELLO 3 reply MUST start with `%` (caught defect 1
   live), pipelined HELLO+CLIENT in one segment MUST answer both (caught
   defect 2 live); cache-court pin: SET EX/PX sets a real TTL + NX/PX shape.

### Embedded real output (this addendum's runs)

```
MIX_BUILD_ROOT=_build-fin1 mix test test/integration/redis_wire_test.exs test/integration/azure_cache_test.exs
Result: 31 passed   (x5 consecutive runs; pins: %-prefix, pipeline, SET EX/PX/NX/PX)

just courtroom-court (leg 3 store hop, 2026-10-29 21:49):
[T03]   api: {"time":"2026-10-30T04:49:42.856Z","level":"info","event":"server_started","port":18080,"sso":true,"store":"redis"}
[T03] leg 3 A: sso/start -> http://127.0.0.1:19445/sso?SAMLRequest=nVJNTwIxEP0rTe...
[T03] leg 3 B: IdP form action=http://127.0.0.1:18080/saml/acs SAMLResponse len=5488
```

### Falsifier status (addendum)

- HELLO %-prefix pin: RAN, PASS (was FAIL against the shipped code — the pin
  caught the clause-order defect before the court did).
- Pipeline pin: RAN, PASS (was FAIL: recv :timeout with the one-command-per-
  recv pump; non-vacuous by construction — it fails on the pre-fix conn).
- SET EX/PX/NX pin: RAN, PASS (was FAIL: TTL -1 pre-`expire:`-option fix).
