# POSH v26.10.30 — Document Index

Index of `/Users/sac/smalt/docs/jira/posh/v26.10.30/`. Status lines are quoted
from each file where present; otherwise the entry is marked UNVERIFIED (no
in-file Status declaration).

> **Dialect decision (v26.10.31):**
> [`../v26.10.31/00-unification-dialect-decision.md`](../v26.10.31/00-unification-dialect-decision.md)
> — the azurerm swap is dialect #1, not the core; the Entra STS wire face is
> dialect #0. smalt-core is a vendor-neutral public-cloud ontology; vendor
> dialects live in posh. POSH-003 and POSH-004 are **DIALECT-SCOPED**
> (dialect #1). Added by GAP-15 wave-2 doc migration (lane 15).

## Root documents

| File | Status |
|---|---|
| `00-charter.md` — POSH charter (Go hyperscaler adapter membrane) | Standing 2026-10-30 (lane X4 doc refresh, on-disk): posh side has landed — Go module, provider, courts |
| `requirements-synthesized.md` — synthesized requirements (final) | UNVERIFIED (no Status line) |
| `working-backwards.md` — Working Backwards doc | "Approved for Synthesis" |
| `schema-v1.md` — provider schema face v1 | UNVERIFIED (no Status line) |
| `_LANES.md` — lane partition for the window | UNVERIFIED (no Status line; header says final, 2026-10-30) |
| `RESOLUTIONS.md` — shared-seam resolutions | UNVERIFIED (no Status line) |

## POSH-001..010

| Order | Status |
|---|---|
| POSH-001 (posh Go module scaffold) | UNVERIFIED (no Status line) |
| POSH-002 (BEAM↔posh membrane protocol, UDS JSON) | UNVERIFIED (no Status line) |
| POSH-003 (Azure ARM face via official SDKs) | UNVERIFIED (no Status line). **DIALECT-SCOPED: dialect #1 (Azure ARM), consumes dialect #0 STS — see decision record `../v26.10.31/00-unification-dialect-decision.md`** |
| POSH-004 (Go Terraform provider, protocol 6, dev_overrides) | UNVERIFIED (no Status line). **DIALECT-SCOPED: dialect #1 (Azure ARM/azurerm) — see decision record `../v26.10.31/00-unification-dialect-decision.md`** |
| POSH-005 (k8s sidecar; kind lane + erlang-port lane) | UNVERIFIED (no Status line) |
| POSH-006 (admission courts; 7-stage ladder in `justfile.d/58-posh.just`) | "Implemented: the full 8-stage ladder lives in justfile.d/58-posh.just" |
| POSH-007 (migration from Elixir provider spike) | APPLIED — ERRC delete executed 2026-10-30; spike archived at tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz, receipt `receipts/migration/posh007-errc-delete-receipt.json` (status APPLIED). Ticket body's line-3 Status ("REMOVED") predates the receipt. Archive pointer (folded from the F15 archive-stub README, tombstone dir hard-deleted 2026-10-30, lane 51): the sole record of the Elixir spike tree is `tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`; active implementation is `adapters/terraform-provider-smalt`. |
| POSH-008 (egress fences) | UNVERIFIED (no Status line) |
| POSH-009 (SDK-parity register) | UNVERIFIED (no Status line) |
| POSH-010 (implementation wave plan) | UNVERIFIED (no Status line) |

## dfcharter/ (DfLSS DMADV phases)

| File | Status |
|---|---|
| `charter-master.md` | UNVERIFIED (no Status line) |
| `triz.md` | UNVERIFIED (no Status line; header notes operator-supplied, authoritative) |
| `define.md` | "DEFINE — ALIVE (document)" |
| `measure.md` | "PARTIAL" |
| `analyze.md` | "ALIVE for document authoring" |
| `design.md` | UNVERIFIED (no Status line) |
| `verify.md` | "PLANNED — doc authored this session; rungs, court, and campaign not yet" |
| `dpmo.md` | "COMPLETE-DOCUMENT / UNVERIFIED-NUMBERS" |
| `andon.md` | UNVERIFIED (no Status line; elaborates charter-master §6) |
| `raci-signoff.md` | "RACI & SIGN-OFF — ALIVE (document)" |

## receipts/

| Receipt | Content |
|---|---|
| `v26.10.30-release-receipt.json` | **v26.10.30 Formal Release Receipt (ADMITTED, 0.0 DPMO, 12-Probe Andon GREEN)** |
| `dflss_audit_receipt.json` | DfLSS audit receipt |
| `wave2-membrane-receipt.json` | Wave-2 membrane receipt |
| `measure/posh002-latency.json` | POSH-002 latency measurement |
| `migration/terraform-provider-smalt-ledger.md` | "archive verified, tree deleted 2026-10-30" |
| `migration/posh007-errc-delete-receipt.json` | POSH-007 ERRC delete receipt (status APPLIED) |
| `mutation/turnstile-flip.json` | Turnstile mutation flip witness |
| `parity/posh009-coverage-gate-green.json` / `posh009-coverage-gate-flip.json` | POSH-009 coverage gate green + flip (anti-vacuity) |
| `posh-court/live-wire-witness-f2.json` | Live-wire witness (lane F2) |
| `posh-court/go-gates-witness-f11.json` | Go gates witness (lane F11) |
| `posh-court/posh-court-green.json` | posh-court green receipt |

## v26.10.30 Core Architecture Technical Briefs

| Domain | Specification Document | Status |
|---|---|---|
| **DX, Time-Travel Replay & Mock Provider** | [`posh/docs/dx-v26.10.30.md`](file:///Users/sac/smalt/posh/docs/dx-v26.10.30.md) | ALIVE (Replay >45k rec/s, Mock ARM >2.7k rps) |
| **TPS Doctor, Predictive Trends & Cluster Healer** | [`docs/jira/posh/v26.10.30/doctor-v26.10.30.md`](file:///Users/sac/smalt/docs/jira/posh/v26.10.30/doctor-v26.10.30.md) | ALIVE (12 probes in 5.36ms, $\tau \le 15\text{s}$ line arrest) |
| **Observability, Differential PProf & OTLP** | [`posh/docs/observability-v26.10.30.md`](file:///Users/sac/smalt/posh/docs/observability-v26.10.30.md) | ALIVE (0 B/op, 0 allocs/op OTLP trace serialization) |
| **CI, Chaos, Mutation Court & Supply Chain** | [`posh/docs/ci-chaos-v26.10.30.md`](file:///Users/sac/smalt/posh/docs/ci-chaos-v26.10.30.md) | ALIVE (93.75% AST kill rate, 188.5ns netem jitter) |
| **Compiler Static Safety, PGO & SIMD** | [`posh/docs/compiler-safety-v26.10.30.md`](file:///Users/sac/smalt/posh/docs/compiler-safety-v26.10.30.md) | ALIVE (`poshvet -budget` 0.0 allocs/op, PGO merge) |

