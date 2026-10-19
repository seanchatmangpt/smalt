# ports-and-planes

Port law for the smalt local substrate. Sources: `lib/smalt/application.ex`
(defaults), `lib/smalt/messaging/amqp_broker.ex` (AMQP listeners),
`scripts/bench/lib.sh` (lane bands), `docs/JUST_REFERENCE.md` (bench private
range). There is no `docs/REGISTRY.md`; the ARM resource registry is the
generated `lib/smalt/registry.ex`.

## Canonical listeners (single-substrate defaults)

| plane | port | config key (`:smalt` app env) | env override | owner |
|---|---|---|---|---|
| ARM control plane (http) | 9443 | `arm_port` | `SMALT_TEST_ARM_PORT` (harnesses) | `Smalt.ArmGateway.Router` via Bandit |
| ARM TLS twin (https) | 9444 | `arm_tls_port` | `SMALT_TEST_ARM_PORT+1` in bench blocks | `Smalt.TLS` + `TlsTwinDispatch` |
| data plane / egress (http) | 8443 | `egress_port` | `SMALT_TEST_EGRESS_PORT` | `Smalt.EgressRouter` |
| AMQP Service Bus | 5672 | `amqp_port` | `SMALT_TEST_AMQP_PORT` | `Smalt.AmqpBroker` (`:sb` mode) |
| AMQP Event Hubs | 5673 | `event_hubs_port` | `SMALT_TEST_AMQP_PORT+3` in bench blocks | `Smalt.AmqpBroker` (`:eh` mode) |
| MCP tool surface (JSON-RPC 2.0, read-only) | 9545 | `mcp_port` | — | `Smalt.Mcp.Router` |

TLS twin rationale (application.ex): azurerm's `ARM_METADATA_HOST` fetch and
Key Vault SDKs hardcode https; the 9444 twin serves `/keys/*` so
azure-keyvault-keys / azure-security-keyvault-* complete against the local
substrate.

Bind law: default bind is loopback `{127,0,0,1}` only (air-gapped emulator).
Override for LAN SDK testing via `SMALT_BIND_IP` or
`config :smalt, bind_ip: {192,168,1,10}` (application.ex, KD-54).

## Lane bands (concurrent fan-out, no collisions)

| band | formula | ports | source |
|---|---|---|---|
| bench lane bN (b1..b12) | `base = 39000 + 10N` | `base..base+5` = ARM, egress/data, amqp, event_hubs, arm_tls, mcp | `scripts/bench/lib.sh` `bench_lane_ports/1` (b1=39010-39015 ... b12=39120-39125) |
| enclave lane eN | lane e1 only (enclave-loop) | private block via `scripts/tf_enclave_loop.sh` | `justfile.d/21-enclave.just` |
| native/terraform lanes | lane-numbered `MIX_BUILD_ROOT=_build-lane<N>` | private ports inside documented range 39000-39999 | `docs/JUST_REFERENCE.md`, `docs/how-to/dev-loop.md` ("Private port allocation") |
| general bench private range | auto-pick or manual | 39000-39999 | `docs/JUST_REFERENCE.md` (`bench` recipe note) |

Rules: a lane pre-flights its whole block with `lsof -iTCP:<port> -sTCP:LISTEN`
and refuses to boot on any held port (fail-closed collision check).
`scripts/bench.py` and `scripts/bench/lib.sh` are witnessing-equivalent spawn
paths. `just sdk-ts` and `test/sdk-smoke/run.mjs` boot their own substrate and
KILL whatever holds 9443 first — never run concurrently with lane substrates.

## SMALT_PLANES

Plane selection narrows WHICH listeners boot; it never changes the port
law. `SMALT_PLANES` (comma list) or `config :smalt, :planes, [...]`;
default `:all` (byte-identical boot). Known planes: `control`, `data`,
`integration`, `identity`; an unknown name refuses boot typed with
`{:invalid_plane, name}` at runtime-config time (`config/runtime.exs`,
`lib/smalt/planes.ex`, `Smalt.Config.planes()` as the read surface). With
`:all` no `config/env/az_prod_<plane>.exs` profile is imported — profiles
are opt-in per explicitly selected plane. Walkthrough:
`docs/tutorials/planes-profiles.md`.

## Environment variables

| var | effect |
|---|---|
| `SMALT_PLANES` | plane selection (see section above) |
| `SMALT_TEST_ARM_PORT` / `SMALT_TEST_EGRESS_PORT` / `SMALT_TEST_AMQP_PORT` / `SMALT_TEST_EVENT_HUBS_PORT` | harness-level port pins read by `scripts/bench/lib.sh` `bench_boot` |
| `SMALT_BENCH_{ARM,DATA,AMQP}_PORT` | `just bench` private-port override |
| `SMALT_BIND_IP` | bind address override (default loopback) |
| `SMALT_SIMULATE_HARDWARE=1` (+ optional `SMALT_HW_PTY`) | opt-in HIL virtual device child |

## See Also

- `lib/smalt/application.ex` — listener child specs and port functions
- `scripts/bench/lib.sh` — lane port law implementation
- `docs/how-to/dev-loop.md` — private port allocation
- `docs/tutorials/planes-profiles.md` — plane selection walkthrough
- `docs/reference/burn-receipt-schema.md` — burn row schema (burn lanes
  write per-plane rows)
