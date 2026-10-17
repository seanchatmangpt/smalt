# architecture

Smalt is a pure-Elixir, BEAM-native substrate that emulates a cloud edge
on loopback so SDKs, CLIs, and Terraform-style tooling can be tested
without a cloud connection. Clean-room notice: see `NOTICE.md`.

> Diátaxis home: `docs/explanation/architecture.md` (moved from
> `docs/ARCHITECTURE.md`; see `docs/jira/v26.10.16/docs-restructure-plan.md`).

## Context (C4 level 1)

```text
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
| `Smalt.Enclave` | native terraform-style lifecycle tier: `lib/smalt/enclave/hcl.ex` (HCL subset parser) → `engine.ex` (topological DAG engine provisioning in-process through `ArmGateway.Router` — no sockets, no TLS, no terraform binary) → `state.ex` (zero-drift plan / cascade destroy / residue audit) → `lifecycle.ex` (test-apply-plan-destroy pipeline); `doctor.ex` preflights the host (toolchain, transport, keychain-trust checks) |

The enclave tier is explained in depth in
`docs/explanation/two-tier-enclave.md`; the lifecycle loop that drives it
is in `docs/how-to/dev-loop.md`.

## Two-tier enclave model

Smalt's terraform story has two deliberately unequal tiers:

- **Native tier (PRIMARY gate)** — the in-process pipeline above. A
  fixture is parsed (`Smalt.Enclave.Hcl.parse/1`), applied through the
  real ARM router in dependency order, planned for zero drift
  (`Smalt.Enclave.State.plan/2` returns `[]`), destroyed with a verified
  cascade, and audited for empty residue. Fully zero-touch and zero TLS:
  no external binary, no keychain trust, no provider plugin. Driven by
  `just apply` / `just verify` / `just destroy` (default `tier=native`).
- **External wire-parity tier (explicit opt-in)** — real `terraform` +
  azurerm provider against the TLS twin (`scripts/tf_cleanroom.sh`,
  `tier=wire`). This tier validates wire parity with real terraform,
  NOT the native engine. It is single-flight on shared global resources
  (fixture state lock, TLS cert regen, provider mirror) and is refused
  with `TIER-WIRE-UNAVAILABLE` unless the trusted-machine gate reports
  PASS. `just apply`/`just destroy` print the wire-tier warning and
  require the explicit opt-in before routing there.

The native tier is the default green gate; the wire tier exists to catch
divergence between the native engine's assumptions and real provider
behavior on the wire.

## Trust boundary ruling (2026-10-16, operator)

The dev workstation does not enter the enclave. Three facts compose the
ruling:

1. **Trust shim covers ad-hoc binaries only.** The DYLD interpose shim
   (`scripts/trust_shim/`; fingerprint-pinned, loopback-gated) is
   silently ignored by hardened-runtime binaries — the azurerm provider
   plugin is hardened-runtime (`codesign` flags `0x10000`), witnessed
   2026-10-16. Re-signing the provider breaks dependency-lock checksums
   (witnessed, reverted).
2. **Keychain trust is an opt-in bootstrap prerequisite**, not an
   enclave capability: one-time `scripts/tf_trust_setup.sh trust` on
   darwin (Go ignores `SSL_CERT_FILE`), gated loudly by fingerprint +
   trust-settings parse. Absent trust = loud per-family SKIP, never a
   fake pass.
3. **Hardened-runtime provider boundary**: darwin Go ignores
   `SSL_CERT_FILE`, so the external wire tier on darwin needs either the
   keychain opt-in or a non-darwin runner. The native tier is unaffected
   by all three facts — that is why it is the primary gate.

## Pinned contracts

| Contract | Value |
|---|---|
| Port map | authoritative copy lives in `README.md` (control 9443, TLS twin 9444, data 8443, AMQP 5672/5673, MCP 9545); do not restate it here |
| Refusal envelope | every refusal is a JSON envelope `{"error": {code, ...}}` — never a bare status; members beyond `code` vary by plane (ARM always carries `message` + `innererror`, optional `target`; some data-plane routes answer `code` only) |
| `Store` | keyed ETS key/value store; put is keyed by the caller's key (not content digest); identical content is NOT a no-op — it overwrites; conditional transitions (`insert_new/3`, `compare_and_swap/4`, `compare_and_swap_delete/3`) are the atomic forms |

Ports and envelope shapes are contracts: tests in `test/wire` and the
SDK smoke tier pin them, and a change that moves a port or alters the
refusal envelope fails the gate.

### Error model: KD `details[]` envelope

The refusal envelope's variable members include a `details` array. The
canonical invariant (KD register, v26.10.16): the error envelope is
byte-identical when `details == []` — an empty `details` list must
serialize exactly as its absence did before the field existed
(`lib/smalt/enclave/engine.ex:495` carries the in-engine face; the KD
row is the register of truth). Consumers that pattern-match the envelope
must not distinguish "no details" from "empty details".

### Blob dot-form DNS limitation

`azurerm`/`go-azure-sdk` build blob endpoints as
`<account>.blob.<dnsSuffixes.storage>` from the metadata doc
(`router.ex:1210`, currently `smalt.local`). `/etc/hosts` cannot
wildcard, so that dot-form is unreachable; smalt serves the
account-in-path form `http://127.0.0.1:8443/{account}/{container}/{blob}`
(`MIGRATION_FROM_EMULATORS.md` pattern). Control-plane-only terraform
fixtures are unaffected: storage account keys/props come from ARM, not
the data plane.

## Regen flow

`lib/smalt/registry.ex` is projected first-class from the ontology pack:

```sh
mix smalt.gen
```

There is no separate `generated/` directory; the registry lives under
`lib/smalt/` and is versioned like any other source. Regen is
deterministic: two runs from the same ontology produce identical output.

## See Also

- `docs/explanation/two-tier-enclave.md` (enclave tier in depth)
- `docs/explanation/zero-drift-model.md` (plan/zero-drift semantics)
- `docs/explanation/cascade-teardown.md` (cascade destroy ordering)
- `docs/how-to/dev-loop.md` (the loop that drives the lifecycle)
