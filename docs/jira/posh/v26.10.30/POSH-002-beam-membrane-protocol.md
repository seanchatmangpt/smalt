# POSH-002: BEAM<->posh membrane protocol (UDS JSON, then gRPC)

## Task
Define and implement the BEAM->posh request/response protocol:
- v1: length-prefixed JSON over Unix domain socket (Erlang :socket / :gen_tcp
  with |local) — port-based companion mode via erlang:open_port for the common lane.
- v2: gRPC over the same socket once POSH-004 lands.
Protocol doc: posh/docs/membrane.md (framing, error envelope, deadlines).
Elixir side: lib/smalt/posh/client.ex (connect, request/3 with typed envelopes,
bounded timeout, reconnect budget) — supervision-owned retries, no Process.sleep.

## Acceptance
- Elixir client round-trips echo + a real ARM GET (via POSH-003) against the
  smalt substrate; latency budget < 5ms overhead per call.
- Failure envelope is typed (transport | upstream | deadline); BEAM never sees a
  raw vendor exception.

## Falsifier
Kill posh mid-stream: client must return a typed transport error and recover on
reconnect — never crash the calling process.
