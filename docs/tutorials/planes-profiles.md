# planes profiles tutorial

Boot only the planes you need. This tutorial walks the `SMALT_PLANES`
selection end to end: full boot, single-plane boot, an invalid name refusal,
and how the choice flows through runtime config into per-plane supervision
subtrees.

By the end you will have: booted the substrate on a reduced plane set,
watched an unknown plane name refuse boot with a typed
`{:invalid_plane, name}`, and identified which supervision subtree owns each
canonical listener.

## What you need

- The smalt repo at `<repo>` (all commands run from there), Elixir toolchain
  (`mix`) on PATH.
- Free loopback ports 9443/9444/8443/5672/5673/9545 (or let the free-port
  probe in `config/test.exs` shift them under `MIX_ENV=test`).
- No docker, no Azure, no cloud.

## The four planes, in one paragraph

smalt's Application tree is partitioned into four plane supervision subtrees
(`lib/smalt/plane/*_supervisor.ex`):

| plane | subtree | owns |
|---|---|---|
| `control` | `Smalt.Plane.ControlSupervisor` | ARM Gateway HTTP router (9443), ARM TLS twin (9444), LRO Notifier + Sweeper, WasmEngine Supervisor |
| `data` | `Smalt.Plane.DataSupervisor` | `Smalt.Store` (shared ETS + DETS mirror), Bandit egress router (8443 — Cosmos SQL AST, Blob) |
| `integration` | `Smalt.Plane.IntegrationSupervisor` | `Smalt.AmqpBroker` (AMQP 1.0 Service Bus 5672, Event Hubs 5673) |
| `identity` | `Smalt.Plane.IdentitySupervisor` | KeyVault data plane + STS token endpoints (hosted across the ARM TLS twin / egress router) |

The default selection is `:all` — today's boot, byte-identical to the
pre-AZB-04 behavior. `Smalt.Planes.resolve/0` reads `SMALT_PLANES` (comma
list) or `config :smalt, :planes`, validates every name against
`[:control, :data, :integration, :identity]`, and writes the parsed list
back to `Application` env `:planes`; `Smalt.Config.planes()` is the single
read surface (`lib/smalt/planes.ex`).

## Step 1: full boot (the default)

```bash
eval "$(just relay-env)"
just up
just status
```

`just status` shows all six listeners. With `:all` no per-plane profile is
imported: `config/runtime.exs` imports a
`config/env/az_prod_<plane>.exs` profile ONLY for explicitly selected
planes — profiles are opt-in per plane, so the default boot imports nothing.

## Step 2: boot a single plane

```bash
SMALT_PLANES=control just up
```

Only the control-plane subtree boots: the ARM router + TLS twin + LRO +
WasmEngine. The data-plane `Store` does not exist. Two in-tree witnesses of
the consequences: `lib/smalt/arm_gateway/lro_sweeper.ex` documents that
under `SMALT_PLANES=control` the data-plane Store is absent, and
`lib/smalt/messaging/amqp/sweeper.ex` likewise for
`SMALT_PLANES=integration` and the data-plane sweeper. Code that assumes a
plane not in the selection must degrade, not assume.

## Step 3: see the typed refusal

```bash
SMALT_PLANES=staging just up   # or: mix run -e 'Smalt.Planes.resolve()'
```

`Smalt.Planes.resolve/0` raises `Smalt.Planes.InvalidPlane`, rendered
exactly as:

```text
{:invalid_plane, :staging} (known planes: [:control, :data, :integration, :identity])
```

The refusal happens at runtime-config time (`config/runtime.exs`), so
releases honor it too — an unknown name never gets as far as a listener.

## Step 4: tear down and reclaim

```bash
just down
```

Port law and lane bands are unchanged by plane selection — see
`docs/reference/ports-and-planes.md` § SMALT_PLANES for the selection
surface and `docs/reference/ports-and-planes.md` for the canonical listener
table.

## What you learned

- `SMALT_PLANES` is a comma list validated at runtime-config time; `:all` is
  the byte-identical default.
- Each selected plane boots its own supervision subtree; profiles are opt-in
  per explicitly selected plane.
- Unknown names refuse boot typed (`{:invalid_plane, name}`), never
  silently.

## See Also

- `docs/reference/ports-and-planes.md` (listener table + SMALT_PLANES)
- `lib/smalt/planes.ex` (resolve/validate law)
- `config/runtime.exs` (profile import law)
- `docs/jira/v26.10.18/receipts/azb-04-plane-loader.md` (landing receipt)
