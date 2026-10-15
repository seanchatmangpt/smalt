# Receipt: MCP/A2A read-only tool surface (elixir-mcp-a2a-pack consumption)

Lane: MCP surface. Date: 2026-10-14. Repo: ~/smalt (canonical checkout).

## What was manufactured

Read-only MCP (JSON-RPC 2.0) tool surface over smalt's real substrate modules,
adapted from `ggen-marketplace/packs/elixir-mcp-a2a-pack`.

| File | Kind | Notes |
|---|---|---|
| `lib/smalt/mcp/gen/smalt_mcp_surface.ttl` | input graph (hand-authored) | one ema:CapabilitySurface + 8 ema:Capability rows, all read-only |
| `lib/smalt/mcp/gen/mcp_descriptor.ex.eex` | EEx adaptation of the pack's `mcp_descriptor.ex.tmpl` | renders module `Smalt.Mcp.Descriptor` |
| `lib/smalt/mcp/generated/mcp_descriptor.ex` | GENERATED via `mix ggen_igniter.sync` (sparql engine, 8 rows) | do not hand-edit; edit the TTL and re-run the sync |
| `lib/smalt/mcp/router.ex` | hand-written | `Smalt.Mcp.Router` Plug router, JSON-RPC 2.0 |
| `test/mcp_test.exs` | hand-written | 20 tests, all green |
| `docs/PACK_INTEGRATION/mcp-a2a.md` | this receipt | |

Hand-written dispatch is read-only by law: the fail-closed gate is
`Smalt.Mcp.Descriptor.requires_authority?/1` (pack convention: an unregistered
id requires authority, i.e. is never callable); any tool id carrying an
actuation verb (put/create/delete/encrypt/sign/complete/...) is refused with
typed `ACTUATION_REFUSED`; other unknown ids get `TOOL_NOT_FOUND`. No DO
surface is reachable from MCP.

## Tools (all read-only, real backing modules)

| tool | backing |
|---|---|
| `substrate.status` | Process.whereis(Smalt.Store / Smalt.Supervisor) + Smalt.Registry ports |
| `substrate.capabilities` | Smalt.Registry.admitted_resource_types/0, latest_version/1, shape_for/1 |
| `arm.get` | Smalt.Store.get(:smalt_resources, downcased resource id) — same key layout as Smalt.ArmGateway.Router |
| `cosmos.query` | Smalt.DataPlane.Cosmos.query_docs/4 (real auth gate + wire shape) |
| `blob.list` | Smalt.Store.list_prefix(:smalt_blobs, ...) projected via BlobStorage.blob_metadata/1 (content-free) |
| `sb.peek` | Smalt.Amqp.QueueStore.peek/2 (no lock, no settlement) |
| `kv.get` | Smalt.Store.get(:smalt_vault_keys, name), key material stripped |
| `doctor.summary` | Supervisor.which_children/1, Cosmos.store_ready?/0, ETS table liveness |

## Child spec for the coordinator (exact line)

Reported, not wired (application.ex owned by another lane):

```elixir
{Bandit,
 plug: {Smalt.Mcp.Router, []},
 scheme: :http,
 port: Application.get_env(:smalt, :mcp_port, 9545)}
```

Add `mcp_port: <port>` to config when wiring. Tests exercise the router over
`Plug.Test` against the live app tree; no listener was left running.

## Gate (real output)

```
$ mix test test/mcp_test.exs
20 tests, 0 failures
```

## Falsifiers

- F1 (descriptor/wire parity): a tools/list that disagrees with the generated
  descriptor — covered by test "generated descriptor agrees with the router
  surface (fail-closed gate)".
- F2 (actuation law): any actuation-named tool call returning anything other
  than `ACTUATION_REFUSED` — 8 actuation names asserted refused by name, plus
  a non-string tool name and a plain-unknown id (`TOOL_NOT_FOUND`).
- F3 (generation replay): re-running the sync command in the TTL header
  reproduces the descriptor. Note: run from scratch project
  /tmp/smalt-mcp-gen (ggen_igniter path-dep on ~/ggen_igniter),
  because another lane's OcelDeviation.ex was compile-broken during
  generation; ggen_igniter refuses an `--out` outside the project root, so
  output was generated to the scratch root's out/ and copied into
  lib/smalt/mcp/generated/mcp_descriptor.ex.

## Disclosures

- No git operations performed; no files touched outside the owned set
  (lib/smalt/mcp/, test/mcp_test.exs, docs/PACK_INTEGRATION/mcp-a2a.md).
- Pre-existing, session-independent: lib/smalt/ocel/revops/OcelDeviation.ex was
  compile-broken mid-session (another lane's in-flight edit); it compiled clean
  by gate time and never affected the MCP gate.
