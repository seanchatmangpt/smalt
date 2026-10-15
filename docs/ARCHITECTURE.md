# Architecture

Smalt is a pure-Elixir, BEAM-native substrate that emulates a cloud edge
on loopback so SDKs, CLIs, and Terraform-style tooling can be tested
without a cloud connection. Clean-room notice: see `NOTICE.md`.

## Context (C4 level 1)

```
+-----------------+       +---------+       +------------------+
| Terraform / SDK | <---> |  smalt  | <---> | loopback stores  |
| CLIs, clients   | HTTPS | substrate |     | (CAS, queues)    |
+-----------------+  AMQP +---------+       +------------------+
```

Clients talk to smalt over the pinned ports below. Smalt persists to
local loopback stores only; it never dials out to a real cloud.

## Containers (C4 level 2)

| Component | Role |
|---|---|
| `ArmGateway` | control-plane listener on 9443; request routing and the refusal envelope |
| data plane (8443) | resource data-plane surface |
| `AmqpBroker` | AMQP Service Bus surface on 5672 |
| Event Hubs surface | AMQP on 5673 |
| `EgressRouter` | the only sanctioned outbound path; blocks non-loopback egress by default |
| `Store` | CAS key/value store; the persistence substrate for all components |

## Pinned contracts

| Contract | Value |
|---|---|
| Port map | authoritative copy lives in `README.md` (control 9443, TLS twin 9444, data 8443, AMQP 5672/5673, MCP 9545); do not restate it here |
| Refusal envelope | every refusal is a typed envelope (code + message + details), never a bare status |
| `Store` | content-addressed (CAS): put is keyed by content digest; identical content is a no-op |

Ports and envelope shapes are contracts: tests in `test/wire` and the
SDK smoke tier pin them, and a change that moves a port or alters the
refusal envelope fails the gate.

## Regen flow

`lib/smalt/registry.ex` is projected first-class from the ontology pack:

```sh
mix smalt.gen
```

There is no separate `generated/` directory; the registry lives under
`lib/smalt/` and is versioned like any other source. Regen is
deterministic: two runs from the same ontology produce identical output.
