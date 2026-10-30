# _LANES — posh window v26.10.30 (final, 2026-10-30)

Canonical checkout `/Users/sac/smalt`, one tree, no worktrees. Coordinator owned
all git transitions; lanes held disjoint file leases. Dispositions below are the
wave's exercised-ownership record (final state, not plans).

## Wave-1 read-only audits

| lane | disposition | ownership exercised |
|---|---|---|
| A1 | read-only audit: Go core scaffold vs POSH-001 | `posh/` read-only |
| A2 | read-only audit: membrane protocol vs POSH-002 | `lib/smalt/posh/` read-only |
| A3 | read-only audit: ARM client vs POSH-003 | `posh/internal/armclient/` read-only |
| A4 | read-only audit: provider vs POSH-004 | `adapters/terraform-provider-smalt/` read-only |
| A5 | read-only audit: sidecar/packaging vs POSH-005 | `k8s/smalt-backend.yaml`, `justfile.d/59-posh-ops.just` read-only |
| A6 | read-only audit: courts/gates vs POSH-006 | `justfile.d/58-posh.just` read-only |
| A7 | read-only audit: egress fences vs POSH-008 | `lib/smalt/posh/egress/` read-only |
| A8 | read-only audit: parity register vs POSH-009 | `docs/jira/posh/v26.10.30/receipts/parity/` read-only |
| A9 | read-only audit: migration ledger vs POSH-007 | `receipts/migration/` read-only |
| A10 | read-only audit: schema-v1 consistency | `schema-v1.md` read-only |
| A11 | read-only audit: charter-vs-disk drift | `00-charter.md` read-only |
| A12 | read-only audit: justfile.d import hygiene | `justfile.d/` read-only |
| A13 | read-only audit: receipts shape (output-bearing) | `receipts/` read-only |
| A14 | read-only audit: k8s stanza vs port-mode supervision | `k8s/smalt-backend.yaml` read-only |
| A15 | read-only audit: DFMEASURE charter cross-check | `dfcharter/` read-only |

## Wave-2 writes

| lane | disposition | ownership exercised |
|---|---|---|
| W-turnstile | turnstile byte contract pinned (op\|\|u64BE ts\|\|payload, digest `0c39d201…`) | `lib/smalt/posh/turnstile.ex` |
| W-client | Elixir client over membrane | `lib/smalt/posh/client.ex` |
| W-port | erlang-port companion, port-mode supervision | `lib/smalt/posh/port.ex`, `lib/smalt/posh/supervisor.ex` |
| W-blake3 | BLAKE3 digest primitive | `lib/smalt/posh/blake3.ex` |
| W-armclient | Go ARM client: STS mint, 60s bearer cache, turnstile-verify | `posh/internal/armclient/client.go` (+ `_test.go`) |
| W-provider | Go terraform provider (terraform-plugin-framework v1.19.0) | `adapters/terraform-provider-smalt/` |
| W-sidecar | posh-membrane sidecar stanza | `k8s/smalt-backend.yaml` |
| W-gates | posh court/gate recipes | `justfile.d/58-posh.just` |
| W-ops | posh-up/posh-down recipes | `justfile.d/59-posh-ops.just` |

## Repairs

| lane | disposition | ownership exercised |
|---|---|---|
| R6 | migration ledger + ERRC-delete draft (`applied: false` in-lane) | `receipts/migration/terraform-provider-smalt-ledger.md`, `posh007-errc-delete-receipt.json` |
| R* (other repairs) | defect repairs on audited surfaces, filed against wave-1 audit findings | per-finding surface, disclosed in lane receipts |

## Phase lanes

| lane | disposition | ownership exercised |
|---|---|---|
| P* | phase sequencing: wave-1 → resolutions → wave-2 → integration; executed to wrap | docs/jira/posh/v26.10.30/ coordination docs |

## Core-team lanes

| lane | disposition | ownership exercised |
|---|---|---|
| C1–C15 | core-team disposition lanes; C6 witness: `arm probe` live 200, 2026-10-30 (receipt embedded in POSH-003 ticket file) | POSH ticket files `POSH-00*.md` |

## Late repairs

| lane | disposition | ownership exercised |
|---|---|---|
| X1–X3 | repair sweep on wave-2 surfaces (typed findings fixed forward) | wave-2-owned files |
| X4 | doc refresh: charter Status block rewritten to on-disk state | `00-charter.md` |

## Finish lanes

| lane | disposition | ownership exercised |
|---|---|---|
| F1–F14 | wrap: receipts index, gates, publish-dry disposition, per-lane commits via coordinator | coordinator-owned transitions |
| F13 (this lane) | final window state: `_LANES.md` + RESOLUTIONS append | `docs/jira/posh/v26.10.30/_LANES.md`, `RESOLUTIONS.md` |
