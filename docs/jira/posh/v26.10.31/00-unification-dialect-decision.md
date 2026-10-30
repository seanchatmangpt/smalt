# Decision Record: Unification Dialect — Public-Cloud-Ontology Core (v26.10.31)

Status: DECIDED (operator, 2026-10-30) — supersede before the second posh shim is written.

## Decision

smalt's core ontology becomes a **vendor-neutral public-cloud ontology** (prior art
first: OASIS TOSCA node types + DMTF CIMI semantics; scan before minting classes).
posh maps vendor dialects (Azure-ARM, Datadog, Stripe, …) INTO that core. smalt never
grows a per-vendor face; the current ARM face is reclassified as **dialect #1 — the
Azure shim, kept byte-identical** because the wire-proven azurerm swap depends on it.

## Laws carried forward (all witnessed in v26.10.30)

1. One unification dialect: vendors translate into smalt-core semantics; dialects
   live and die in posh.
2. Ontology-gated admission: new faces close via ontology ttl + regen (GraphLaw
   refuses ad-hoc routes); registry.ex is generated, never hand-edited.
3. Receipts on every mutation (turnstile fence, now live on the ARM face); egress
   allowlist per target — posh.yaml is ceiling, graph is source.
4. posh stays stateless and disposable (SPAF Rule 1). Cautionary witness: the one
   SPAF violation found all wave (internal/wasm competing runtime, arbitrary-byte
   admission, dead code) — any posh component owning state or admission stops
   being a shim.

## What migrates vs carries over

- Carries over unchanged: GraphLaw admission mechanics, turnstile/receipt law,
  egress fences, receipt formats, ggen projection discipline, courts.
- Migrates: api-version ceilings move into the dialect layer (Azure vocabulary);
  the ARM face reclassifies from native semantics to dialect #1.
- Additive path (no rewrite of wire-proven surfaces): land smalt-core.ttl as the
  admission layer ABOVE existing registry families; grow dialect #2 (first real
  consumer: Stripe or Datadog per charter consumer list) mapping into the core;
  only then evaluate inverting the ARM face into posh.

## Open questions for the v26.10.31 charter

1. TOSCA/CIMI coverage scan: do smalt's registry families (containerApps, kv,
   storage, identity, RBAC, messaging) map 1:1 onto TOSCA node types, or do
   Azure-specific shapes (LRO envelopes, api-version ladders) need a core-level
   equivalent (e.g. a neutral lifecycle/versions vocabulary)?
2. Does the neutral core need its own wire face (posh dialects project to core
   IRIs directly), or is the core admission/ontology-only with dialect faces
   staying wire-shaped? (Receipts favor ontology-only first.)
3. Identity semantics: Entra/SAML shapes are Azure-flavored — neutral core needs
   a principal/credential model before the first non-Azure dialect.

## Evidence base

v26.10.30 wave: requirements-synthesized.md (architecture settled), triz.md
(Principle 24 intermediary), gaps/01-76 (parity, admission law, fence landing),
dfcharter/* (SPAF contract), and the byte-identical azurerm swap witness
(dev_overrides + Go provider vs live smalt ARM plane).

## AMENDMENT (2026-10-30, operator): ZERO PROPRIETARY NAMESPACES

The "smalt: minted core classes" approach (and M13's `registry_core.ex` design that
depends on it) is SUPERSEDED. The admission core speaks ONLY ratified standards IRIs:

- Compute/Containers/Storage: `tosca:` (OASIS simple/yaml 1.3 ns) & `cimi:` (DMTF/2)
- Access control: `acl:` (W3C WAC) & `rbac:` (NIST CSRC)
- Crypto material: `kmip:` (OASIS v1.4)
- Receipts/proofs: `sec:` (w3id.org/security)
- Tenancy/boundaries: `org:` (W3C) & `dcterms:` (DCMI)

posh projects vendor payloads DIRECTLY to these IRIs — no intermediate smalt dialect
layer, nothing to maintain/version/license. SHACL `sh:closed true` admission shapes
reject any unmappable vendor attribute at admission (fail-closed, zero state leakage).

Consequences: M13's `smalt-core.ttl`/`registry_core.ex` two-layer design is amended to
standard-IRI classes (the layer split stands; the class vocabulary does not). The pack
landing as `/Users/sac/ggen-marketplace/packs/smalt-core-pack/` carries the shapes, the
vendored ontologies, and the admission gates (rdflib/pySHACL positive+negative/ggen sync).
Known honesty obligation: TOSCA YAML 1.3 and KMIP have no official RDF encodings — the
pack vendors SODALITE's TOSCA OWL (where usable) and provenance-marked mini-ontologies
for KMIP/RBAC, and PACK-NOTES.md records every IRI reconciliation against the real
standards.
