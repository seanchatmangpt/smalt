# POSH → smalt: Synthesized Requirements (final, 2026-10-30)

Derived from the 20-agent Explore wave + implementation receipts. Normative.
Companion docs: charter-master.md, triz.md, working-backwards.md, dfcharter/*.

## Architecture requirement (settled)

POSH = asymmetric membrane inside smalt, tri-tier per the SPAF contract:
1. BEAM core (smalt) — state, supervision, orchestration; never raw
   crypto/byte-unpacking on actor heaps.
2. Go adapter (stateless) — Terraform provider + Azure/K8s protocol shims;
   zero domain state, zero persistent DBs.
3. `#![no_std]` Rust BLAKE3 kernel — 32-byte Merkle receipts, CC=1, no heap
   allocs (Phase 4; v1 uses SHA-256 honestly named as such).

## Hard requirements

1. Invisible azurerm swap: configs byte-unchanged via dev_overrides — TF 1.14
   REJECTS labeled dev_overrides blocks (attribute form only, witnessed live).
2. Transport: kind cluster, host 9443 -> node 30943, plain-HTTP ARM face;
   /metadata/endpoints is the only auth-exempt health anchor on 9443 (/healthz
   is bearer-gated there; lives on egress 8443).
3. Auth: STS mint POST {endpoint}/{tenant}/oauth2/v2.0/token,
   client_credentials, zero-guid client, secret smalt-sovereign-mock-secret;
   token cached to expiry-60s.
4. API-version gate is monotonic per type (KD-78): registry.ex is the
   authority — resourceGroups 2023-07-01, containerApps/managedEnvironments
   2023-05-01, vaults 2023-02-01, secrets 2023-07-01, UAI 2023-04-01, FIC
   2023-01-31 (flat RG-scope), ACR 2023-06-preview (required version_base
   day-less normalization + AcrRouter precedence fix). 2024-03-01 ladders
   are refused.
5. Substrate divergences the provider must absorb: managedEnvironmentId (not
   environmentId); KV secret PUT needs top-level location; containerApps
   refuse traffic-weight on first PUT; numeric memory (not "1Gi"); secrets
   never echoed on read (keep prior state); GraphLaw ontology admission
   decides which types exist — gaps close via ontology.ttl + regen, NEVER
   hand-editing registry.ex.
6. Receipt law: every mutation passes the turnstile
   (BLAKE3(delta || node || ts || stateRoot), 32 bytes, v1 SHA-256),
   append-only prev-hash-chained event log; no unreceipted delta admitted
   (type-signature fence).
7. Turtle/ggen: routing/admission policies as .ttl + SHACL; ggen sync
   requires a ggen.toml manifest in the pack (FM-CONFIG-001); templates
   project Elixir GenStage + Go adapters; hand-written code = irreducible
   residue only.
8. Verification: fail-closed courts with loud typed skips (exit 3) —
   falsifiers: STS-bearer wire inspection + destroy + zero residue,
   plan -detailed-exitcode = 0, non-vacuity mutations must flip every gate
   (a court that cannot flip is FAIL).
9. Docker/colima must be up; egress allowlist default-deny (fail-closed boot
   on missing posh.yaml); role_definition is GET-only on smalt (create-local
   + loud UNSUPPORTED only).
