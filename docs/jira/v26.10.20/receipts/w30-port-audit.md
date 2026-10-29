# W30-E — Port-collision audit: smalt port plan vs official Azure emulators

- **Date**: 2026-10-21
- **Lane**: W30-E (bench-runner), repo `/Users/sac/smalt`
- **Subject**: smalt's full port plan vs official emulator default ports
- **Trigger**: deep-research integration caution (azure-emulators-deep-research
  caveat: "Port-collision risk between Azurite defaults (10000-10002) and
  smalt's own listeners is flagged but unverified against smalt's live port
  map") + open question in that receipt: "Does Azurite's default port range
  (10000-10002) collide with any smalt lane or bench-lane port allocation?"
- **Standing**: ALIVE (static audit over on-disk config + registry; no runtime
  listeners probed — a live `lsof` sweep is out of lane scope and is named as
  the follow-up falsifier)

## Method

Grepped the port sources of truth on disk (not from memory):

- `lib/smalt/config.ex` — canonical listener defaults (lines 49, 94, 112, 211,
  229, 346 and accessors at 546-650)
- `scripts/bench/REGISTRY.md` — lane-block law and non-b allocations
  (audited 2026-10-15, lane R3)
- `workspace/scripts/e2e-court.mjs` (`WS_PORT || '3100'`),
  `workspace/scripts/sync_fault_probe.mjs` (Y4_BFF_BASE :3100)
- `docs/jira/v26.10.20/receipts/azure-emulators-deep-research.md` for
  emulator default ports (first-party Microsoft doc citations, fetched
  2026-10-21)

## smalt port plan (verified on disk)

| port | surface | source |
|---|---|---|
| 9443 | ARM control plane | `config.ex:94,559` (`arm_port/0`) |
| 9444 | ARM TLS twin | `config.ex:112,566` (`arm_tls_port/0 SDK legs) |
| 8443 | data plane / egress | `config.ex:211,600` (`egress_port/0`) |
| 5672 | AMQP Service Bus | `config.ex:49,546` (`amqp_port/0`) |
| 5673 | Event Hubs AMQP | `config.ex:229,604` (`event_hubs_port/0`) |
| 9545 | MCP tool surface | `config.ex:346,632` (`mcp_port/0`) |
| 3100 | workspace BFF / Next.js (WS_PORT default) | `workspace/scripts/e2e-court.mjs:480`, `sync_fault_probe.mjs:26` |
| 39010..39125 | b1..b12 bench lanes (39000+10N..+5) | REGISTRY.md port law |
| 39210..39285 | c-law lanes (39200+10N..+5) | REGISTRY.md |
| 39290..39294 | c9 enclave loop | REGISTRY.md |
| 39370..39375 | e1 enclave loop | REGISTRY.md |
| 39490 | a9; 39640..39650 lifecycle_harness; 39680..39684 c3; 39840..39843 b6; 39850..39853 c5 | REGISTRY.md legacy blocks |
| b90 / b13 | private substrate blocks via `scripts/substrate-ctl up --block <name>` | receipts kd73-74-wire-witness.md, x3 (KD-131) |

Note on "3199": the only `3199` match in the repo is a hex substring inside an
ML-DSA-65 KAT literal in `lib/smalt/trust_profile/trust_profile.ex:657` — a
false positive, not a port. No live 3199 listener or config default exists.
Flagged so the port plan is stated from the tree, not the dispatch prose.

## Official emulator default ports (first-party docs, via deep-research receipt)

| emulator | default ports | source (deep-research claim) |
|---|---|---|
| Azurite | Blob 10000, Queue 10001, 10002 Table | claim 1 |
| Service Bus emulator | AMQP 5672, management HTTP 5300 | claim 4 |
| Cosmos DB classic | 8081 (gateway + Data Explorer) | claim 7 |
| Cosmos DB vNext (Linux) | 8080 + health probes | claim 6 |
| Event Hubs emulator | AMQP (compose default also 5672-class; custom-port Kafka issues documented, issue #54) | claim 8 |

## Collision verdicts

| verdict | smalt | emulator | assessment |
|---|---|---|
| **COLLISION** | 5672 (AMQP SB plane) | Service Bus emulator AMQP 5672 (EH emulator compose also defaults 5672-class) | the known one, confirmed: any co-resident SB emulator on defaults takes smalt's SB plane down (or vice versa, last binder wins / connect refused). Deep-research issue #5 witnesses a real 5672 contention incident (RabbitMQ occupying 5672 in the EH emulator repo). |
| near-miss | 5673 (smalt EH) vs SB emulator 5300 mgmt port | none | adjacent AMQP family; no overlap but same operator reflex ("it's the messaging emulator, it's fine on defaults") is exactly the reflex that binds 5672. |
| near-miss | lane band 39xxx | — | lane blocks are disjoint from 10000-10002/8080/8081/5300/5672 — the open question in the deep-research receipt answers NO collision between Azurite 10000-100 vs lane blocks; bench_lane_ports only enforces the b-law internally, it does not defend 10000-family. `bench_boot` lsof pre-flight catches a live 10000-holder only if a lane actually binds it. |
| near-miss | 9443/9444/8443/9545/3100 | none of 8080/8081/5300/10000-10002 | clean; 8080/8081 live only in "common dev-port territory" (proxies, other tools) — co-residency risk is generic dev-host noise, not emulator-specific. |
| clean | 10000-10002 (Azurite) vs smalt plan | — | no smalt default listener in 10000-family; only deliberate consumer is `scripts/stress/vs_azurite.py` (binds/targets 10000 by design). |
| clean | 3100 (workspace) vs anything | — | 3000-3100 is Next-class territory; emulators do not use it. |

## Isolation rule (the landing)

**Any co-resident official emulator must be pinned off smalt's plan: shifted
ports or a private lane block.**

- Azurite: `--blobPort/--queuePort/--tablePort` (+ `--location`) or a
  container port-map shift; never run defaults alongside a booted substrate.
- Service Bus emulator: shift the compose AMQP 5672 and `EMULATOR_HTTP_PORT`
  5300 via compose port mapping.
- Cosmos: classic `--port` flag; vNext compose port map. vNext compose map.
- smalt side: boot lane-scoped substrates on private blocks
  (`scripts/substrate-ctl up --block b13|b90`), per the b13/b90 receipt
  precedent (kd73-74-wire-witness.md, KD-131/x3 receipt) — never the shared
  canonical ports when an emulator is up.

Enforcement status: the isolation rule above is prose, not a gate. `bench_boot`
preflight (lsof) refuses a lane on a held port — that is the existing
mechanism, and it covers lane scopes only, not the canonical 5672 plane. A
fail-closed port-plan gate (e.g. `just doctor` asserting 5672 is not held by a
non-smalt process, negative-fixture via a dummy holder) is the named successor
mechanism and is NOT landed by this lane (out of scope).

## Falsifier / follow-up

- Live `lsof` sweep on a dev host with an emulator co-resident would confirm
  the 5672 collision at runtime; static audit stands without it.
- `scripts/stress/vs_azurite.py` already models the deliberate-cross-compare
  shape (smalt vs Azurite on 10000). A successor lane can re-run it with the
  shifted-port rule applied.

## Files touched by this lane

- `docs/jira/v26.10.20/receipts/w30-port-audit.md` (this file, new)
- `docs/TESTBED.md` — "Port plan vs official emulators" subsection (edit)
