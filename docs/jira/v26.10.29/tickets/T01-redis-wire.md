# T01 — Redis RESP2 wire listener over AzureCache

- window: v26.10.29 · status: LANDED (ALIVE — receipt
  `receipts/r1-t01-redis-wire.md`) · consumer need: `REDIS_URL` on
  `apps/api` (real `redis` npm v6 client + `connect-redis`)

## Scope

Pure byte-pump TCP listener exactly as the v26.10.28 r15 receipt reserved:
frame RESP2 multibulk/inline commands off the socket, call
`Smalt.DataPlane.AzureCache.handle(account, command_list)`, write the
already-RESP2-encoded reply back. No cache logic in the wire layer.

## Surface

- `Smalt.DataPlane.RedisWire` — facade supervisor: listener (acceptor) +
  DynamicSupervisor for per-connection processes (AmqpBroker house pattern).
- Port: `config :smalt, :redis_port` (default 6380), bind via
  `Smalt.Config.bind_ip()` law. Bind failure contained (listener child
  stops, app survives) — same containment as the AMQP listeners.
- Account selection: `AUTH [username] password` — a valid account token
  selects the AzureCache account; otherwise the default account.
- QUIT closes the socket. Connection crash contained (temporary child).

## Honesty flip (receipt-gated)

`AzureCache` INFO/registry rows (`tcp_port`, `wireListener`, `port`/`sslPort`)
report the no-wire default truthfully today. When `:redis_port` is
configured they must name the wire (regenerate record from configured port).
Flip lands with the T01 court + receipt; v26.10.28 pins that assert the
no-wire default are updated in the same commit and receipted.

## Falsifier

A real `redis` npm client (consumer repo, node 22) performs SET/GET/EXPIRE/
TTL/HSET/HGETALL/session round-trips over `redis://127.0.0.1:6380` —
protocol frames validated by the real client parser, not by our own
encoder. Court: `test/integration/redis_wire_test.exs` (in-BEAM, real
:gen_tcp client) + T03 consumer leg (real npm client).
