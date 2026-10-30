# POSH Charter — Go Hyperscaler Adapter Membrane (v26.10.30)

## Problem

smalt (BEAM) interfaces with hyperscaler/PaaS/control-plane ecosystems (Azure ARM,
Terraform, K8s) whose native protocol implementations are Go. Pure-BEAM integration
costs: bespoke API clients, hand-rolled STS/signing, community-package drift,
reverse-engineered gRPC. The 2026-10-30 Elixir Terraform-provider spike proved the
protocol surface is implementable in BEAM, but at O(protocol-maintenance) recurring cost.

## Decision

Build **posh**: a Go "foreign membrane" adapter INSIDE smalt.

```
BEAM core (smalt) --UDS/localhost JSON/gRPC--> posh (Go adapter) --> hyperscalers
```

## Laws (rules of engagement)

1. **Unidirectional dependency**: BEAM commands posh; posh never owns domain state.
2. **Stateless plumbing**: posh retains zero long-term domain state; token caches and
   connection pools are the only live state, and all of it is rebuildable.
3. **Decoupled deployment**: posh ships as (a) an erlang-port companion process and
   (b) a sidecar container (same pod) for the k8s/kind lanes.
4. **Every posh capability is admitted through smalt's existing court/receipt
   discipline** — a posh PR without a falsifier receipt does not land.
5. **BEAM purity preserved**: smalt lib/ gains no vendor SDK logic; all vendor mess
   (SigV4, STS refresh, retries, HTTP/2 quirks) lives behind the membrane.

## In-scope first consumers

- Terraform provider (Go terraform-plugin-framework, protocol 6) — replaces the
  Elixir-provider spike; azurerm-shaped configs stay unchanged via dev_overrides.
- Azure ARM client (official azure-sdk-for-go / azidentity) backing smalt parity lanes.
- Kubernetes control (client-go) for the kind/swarm lanes.

## Out of scope

- Any business logic, storage, or scheduling in posh.
- Real-cloud egress from CI (posh targets smalt substrate + kind; real-cloud legs are
  opt-in lanes).

## Falsifier (charter-level)

A capability that requires editing smalt lib/ to absorb a vendor protocol detail is a
posh charter violation — the fix belongs behind the membrane.

## Status

Standing 2026-10-30 (lane X4 doc refresh, on-disk): the posh side has landed — Go
core (`posh/` Go module), the terraform provider (`adapters/terraform-provider-smalt/`,
terraform-plugin-framework v1.19.0), the Elixir membrane (`lib/posh/`), and the
Elixir client. Gates and courts live in `justfile.d/58-posh.just` (`just posh-*`).

Landed this window:
- **POSH-003** (azure arm client): `posh/internal/armclient/client.go` — STS mint,
  60s bearer token cache, turnstile-verify; `arm probe` live 200 witness
  2026-10-30 (C6 receipt, in POSH-003 ticket file).
- **POSH-005** (k8s sidecar): port-mode supervision in
  `lib/smalt/posh/port.ex`; posh-membrane sidecar stanza in `k8s/smalt-backend.yaml`;
  `posh-up`/`posh-down` recipes in `justfile.d/59-posh-ops.just`.
- **ERRC-delete APPLIED** 2026-10-30 per
  `receipts/migration/posh007-errc-delete-receipt.json` (status APPLIED): root
  Elixir spike archived at
  `tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`
  (sha256 `f0fe321b…`, verified) and deleted; the adapters Go port stays
  (31-file ledger is a disposition record, not a deletion plan).

Remaining open: POSH-006 (court wiring + receipts: posh-court green, mutation,
measure) and KD-POSH-5 (copy-in).
