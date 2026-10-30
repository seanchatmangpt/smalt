# v26.10.31 — Unification Dialect: Public-Cloud-Ontology Core

Window goal: formalize smalt's core ontology as a **vendor-neutral public-cloud ontology**
(prior art first: OASIS TOSCA node types + DMTF CIMI semantics + KMIP), with POSH
as the translation membrane mapping vendor dialects (starting with Azure-ARM as Dialect #1)
into this neutral core.

## Verdict

**ALIVE.** Core ontology (`priv/ontologies/public-cloud-core.ttl`) landed and verified
with zero proprietary namespaces and fail-closed closed-world admission shapes.
See [FINAL.md](FINAL.md) and [00-charter.md](00-charter.md).

## Key Architecture & Artifacts

- **Neutral Core Ontology**: [public-cloud-core.ttl](../../../priv/ontologies/public-cloud-core.ttl) —
  318 triples, 9 closed shapes under `tosca:`, `cimi:`, and `kmip:`.
- **Closed-World Admission Court**: `scripts/verify_public_cloud_ontology.py` (ALIVE / GREEN).
- **Decision Record**: [00-unification-dialect-decision.md](../posh/v26.10.31/00-unification-dialect-decision.md) (DECIDED, operator 2026-10-30).
- **Charter**: [00-charter.md](00-charter.md) — 15-lane unification roadmap.
- **Credential Model**: [09-credential-core-model.md](gaps/09-credential-core-model.md) —
  `CredentialRequest` / `Scope` / `SecretRef` neutral abstraction.
- **Two-Layer Admission**: [13-admission-split.md](../posh/v26.10.31/gaps/13-admission-split.md) —
  Layer 1 capability authority vs Layer 2 dialect mappings.
- **Provider Parity & Honesty**: `adapters/terraform-provider-smalt/` — 12 resources + 7 data sources,
  import-state test suite (12 blocks PASS), turnstile BLAKE3 receipt verification.
- **DoD Consolidation**: [09-dod-consolidated.md](gaps/09-dod-consolidated.md) — smalt baseline & harness matrix.
