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
| plane supervisors (AZB-09) | `Smalt.Plane.ControlSupervisor` (ARM 9443 + TLS twin 9444) and `Smalt.Plane.DataSupervisor` (egress 8443) partition the listener surface; see the plane-subtree section below |

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
(`lib/smalt/arm_gateway/router.ex:552` and `:573` carry the ARM face —
`details` is added to the envelope only when non-empty, so the
serialization is byte-identical when `details == []`; the KD
row is the register of truth). Consumers that pattern-match the envelope
must not distinguish "no details" from "empty details".

### Blob dot-form DNS limitation

`azurerm`/`go-azure-sdk` build blob endpoints as
`<account>.blob.<dnsSuffixes.storage>` from the metadata doc
(`router.ex:2475-2490`, currently `smalt.local`). `/etc/hosts` cannot
wildcard, so that dot-form is unreachable; smalt serves the
account-in-path form `http://127.0.0.1:8443/{account}/{container}/{blob}`
(`MIGRATION_FROM_EMULATORS.md` pattern). Control-plane-only terraform
fixtures are unaffected: storage account keys/props come from ARM, not
the data plane.

## Plane-scoped supervision subtrees (AZB-09)

The supervision tree is partitioned by plane, not by accident of
child-list order. `Smalt.Planes` (`lib/smalt/planes.ex`) validates the
`SMALT_PLANES` selection (`:control`, `:data`, `:integration`,
`:identity`; unknown names refuse boot with
`{:invalid_plane, name}`). `Smalt.Application` starts the shared top-level
infra (telemetry `RollingCounters`, the MCP Bandit listener with a bound
10s graceful stop, optional virtual HIL hardware) plus one subtree per
selected plane: `Smalt.Plane.ControlSupervisor` owns the ARM listener
(9443) and its TLS twin (9444), `Smalt.Plane.DataSupervisor` owns the
egress router (8443). Every Bandit child carries a bounded `shutdown` —
a stuck ThousandIsland listener hung tree stop >60s in the burn ring
before the bound landed (AZB-22b). Receipt:
`docs/jira/v26.10.18/receipts/azb-09-plane-subtrees.md`.

## Long-running operations: one terminal writer

ARM long-running operations are store-backed records in
`:smalt_operations` (`lib/smalt/arm_gateway/lro.ex`): 202 +
`Retry-After` until the configured delay elapses, then the terminal
body. Convergence is OWNED, not emergent: `LRO.Sweeper`
(`lib/smalt/arm_gateway/lro_sweeper.ex`) is the SINGLE terminal writer —
the only component that drives the public `evaluate/2` / `fail_closed/2`
persistence path — and it also flips due records at rest on a periodic
pass, so an operation never polled still reaches terminal. The read
path and the `LRO.Notifier`'s due-check route their persistence through
the writer, so the swept and polled paths cannot diverge. The Notifier
(`lib/smalt/arm_gateway/lro_notifier.ex`) is a SIGNAL layer only: it
never writes the store, and publishes each terminal so `LRO.await/3`
waiters wake on the explicit `:lro_terminal` message instead of
polling (deny-by-default registration scoped to the record's
subscription; `await/3` falls back to bounded store polling if the
Notifier is down). Fail-closed contract: a malformed record fails
closed at read, never wedged. Receipts:
`docs/jira/v26.10.18/receipts/b4-lro-store.md`,
`docs/jira/v26.10.18/receipts/b-lro-notifier.md`.

## Event Grid: the at-least-once engine

`Smalt.Messaging.EventGrid` (`lib/smalt/messaging/event_grid.ex`) is the
integration-plane fan-out engine (AZB-07): CloudEvent-shaped events,
per-event acks, dedup on event `id` (`:duplicate` vs `:fresh`), and
un-acked events stay queued across a subscriber crash and redeliver to
the recovered subscriber — never loss. `delivery_mode` is read through
one source (`Smalt.Config.event_grid/0`); only `:at_least_once` is
implemented — any other value is typed-refused at delivery, and the
anti-vacuity shim (ack-before-dispatch) witnesses why the lossy mode is
not hidden behind a fake pass. Redelivery after recovery is driven by
the resubscribe plus a bounded `send_after` backoff — no sleeps. The
engine is lazy-started (no application.ex child by default). Receipt:
`docs/jira/v26.10.18/receipts/azb-07-integration-plane.md`.

## Burn architecture

Saturation burn is a first-class lane: `docker/burn/soak.sh` runs N
`yes` CPU hogs (degraded-host law), an AMQP atom-flood generator
(partial request line → mid-request close on 5672, reproducing the
i22 logger-flood class), and the full offline suite plus the
`:amqp_wire` tier across rounds — failures are classified against
`docs/jira/v26.10.17/FLAKE_LEDGER.md`, so only UNLEDGERED failures fail
the burn. `docker/burn/parallel-matrix.sh` runs a 4-container compose
matrix and asserts N/N clean. JSONL rows land in `tmp/burn-soak-*.jsonl`
(lanes write only their own files). Deadline polls everywhere — no
fixed sleeps. Drive with `just burn` / `burn-soak` / `burn-chaos` /
`burn-matrix` / `burn-clean`
(`justfile.d/30-burn.just`). Receipts:
`docs/jira/v26.10.18/receipts/azb-22-burn-ring.md`,
`docs/jira/v26.10.18/receipts/burn-soak-live.md`.

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
- `docs/NO_SLEEP_DOCTRINE.md` — observation-not-sleep discipline; the
  burn lanes and test tiers here poll observables, never wait-and-hope
