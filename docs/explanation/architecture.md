# Architecture

Smalt is a pure-Elixir, BEAM-native substrate that emulates a cloud edge
on loopback so SDKs, CLIs, and Terraform-style tooling can be tested
without a cloud connection. Clean-room notice: see `NOTICE.md`.

## Context (C4 level 1)

```
+-----------------+       +---------+       +------------------+
| Terraform / SDK | <---> |  smalt  | <---> | loopback stores  |
| CLIs, clients   | HTTPS | substrate |     | (keyed stores, queues) |
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
| `EgressRouter` | data-plane router on 8443 — the single inbound surface where SDK/CLI cloud calls terminate; the substrate makes no outbound connections at all (nothing dials out, so there is nothing to block) |
| `Store` | keyed ETS key/value store with a durable DETS mirror (`lib/smalt/store/dets_mirror.ex`); the persistence substrate for all components; conditional transitions (`insert_new`, `compare_and_swap`) are single-ETS-window atomic |

## Pinned contracts

| Contract | Value |
|---|---|
| Port map | authoritative copy lives in `README.md` (control 9443, TLS twin 9444, data 8443, AMQP 5672/5673, MCP 9545); do not restate it here |
| Refusal envelope | every refusal is a JSON envelope `{"error": {code, ...}}` — never a bare status; members beyond `code` vary by plane (ARM always carries `message` + `innererror`, optional `target`; some data-plane routes answer `code` only) |
| `Store` | keyed ETS key/value store; put is keyed by the caller's key (not content digest); identical content is NOT a no-op — it overwrites; conditional transitions (`insert_new/3`, `compare_and_swap/4`, `compare_and_swap_delete/3`) are the atomic forms |

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
