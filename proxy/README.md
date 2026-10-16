# smalt_proxy — substrate proxy scaffold (WO v26.10.15/23)

Standalone mix project: the cheaper 20% of WO-01 (substrate daemon).
Zero coupling to the root `:smalt` project — `cd proxy && mix compile` is
isolated by construction (own `mix.exs`, no deps, not an umbrella child).

## What is here now (scaffold)

- `SmaltProxy.Namespace` — per-lane prefix algebra. `<lane> ::= [a-z0-9]{1,8}`,
  `prefix = "s" <> lane <> "-"`. Scan semantics mirror the root's
  `Smalt.Store.list_prefix/2` (bounded prefix scan, `prefix <> <<0xFF>>`
  upper bound). Property-tested standalone in `test/smalt_proxy_test.exs`.
- `SmaltProxy.Router` — GenServer-owned loopback listener on the single
  well-known port **9460** (127.0.0.1 only). Currently an echo server;
  the real substrate dispatch is a stub.
- `SmaltProxy.Application` — supervisor (`one_for_one`).

## Dispatch contract (stub)

Lane code connects to `127.0.0.1:9460` and addresses resources as
`prefix <> name` on every stateful surface (Store keys, SB queue names,
EH hub names, Cosmos db/container, blob containers) — identical to WO-01 §3.
The proxy multiplexes to logically namespaced substrate resources; one BEAM,
one port, no flock, no per-lane port allocation (WO-23 §1).

Not yet implemented (stubs): actual forwarding to substrate endpoints
(AMQP 5672 / EH / Cosmos / blob twins), `GET /metadata/endpoints`, and the
`substrate.sh` shim repoint (WO-23 §3.5 — owned by later lanes, not this
scaffold).

## Which v26.10.15 lanes wire it

- **WO-23 falsifier lanes** (F1/F2): 20-lane fan-out runs its SDK smoke +
  Store churn slices against this listener instead of private boots.
- **WO-01** (substrate daemon): grows the launchd/identity layer onto this
  GenServer once the proxy survives a full wave; the prefix contract is
  already shared.
- **WO-05 / fin-05 consumers** (per docs/jira/v26.10.15/): SDK smoke lanes
  stop allocating port blocks; `substrate.sh` shims to
  "verify proxy listeners, else boot proxy".

## Verify

```
cd proxy && mix compile   # exit 0
cd proxy && mix test      # green
```

Root tree untouched: no umbrella/children edit, no justfile entry.
