# Gap 13: Two-Layer Admission Split (Core Classes vs Dialect Mappings)

Lane 13 of 17, v26.10.31. Read-mostly design; no lib/ changes in this lane.

## H1: Problem

Admission in smalt conflates three concerns in one ontology + one generated
artifact:

1. Which abstract capabilities exist (registry, compute, secrets, messaging,
   identity) — dialect-neutral facts.
2. Which wire strings the emulated hyperscaler (ARM) uses for those
   capabilities (`Microsoft.ContainerRegistry/registries`, `Microsoft.App/
   containerApps`, ...) — dialect data.
3. Which api-versions each wire type accepts — dialect versioning, per
   gaps/12 decision.

Today all three live in `smalt-substrate-pack/ontology.ttl` (armChildControlPlane
rows, TypeBinding rows) and project into one `lib/smalt/registry.ex`
(`@admitted_resource_types`, `@type_shapes`, `@api_versions`) whose admission
functions are called from `plug/common.ex` (`check_api_version`/`check_version`)
and `arm/resource_providers.ex` (line 4164 `Registry.admitted?/1`).

## H2: Dialect decision recap (per gaps/12)

- LAYER 1: neutral core classes are the GraphLaw admission authority. TOSCA-
  mapped: `ObjectRegistry`, `ComputeEnvironment`, `SecretStore`, `MessageHub`,
  `IdentityPrincipal`, `ContainerWorkload`, `NetworkFabric`, `DataStore`,
  `TrustAnchor` (KeyVault/HSM/attestation/ledger), `GovernanceSurface`
  (locks/policy/diagnostic settings/DevTest schedules).
- LAYER 2: dialect-type-mappings are GENERATED projections binding each
  `Microsoft.*` wire string to a core class. Adding a second dialect must not
  touch LAYER 1.

## H3: Exactly what splits

### H3.1 ontology.ttl (pack)

Stays in `smalt-substrate-pack/ontology.ttl` (LAYER 1, admission authority):
- `smalt:ControlPlane`/`DataPlane`/`MessagingBroker` class hierarchy (lines
  14-47) — re-parent under core classes in phase 2; content unchanged phase 1.
- TypeBinding rows: `smalt:resourceType`, `smalt:apiVersion`, `smalt:shape`
  stay where they are in phase 1; phase 2 re-skins `resourceType` strings as
  dialect-mapping data.

Moves to a NEW generated/curated dialect-mapping TTL (LAYER 2), new file
`smalt-dialect-arm.ttl` in the same pack:
- Every `Microsoft.*` wire string currently on `smalt:ArmControlPlane`,
  `smalt:armChildControlPlane`, and the `smalt:inv-*` inventory rows — i.e.
  the 58 admitted types + 4 inventory-only types.
- Each mapping row: wire string, core class IRI, `smalt:apiVersion` lattice
  top, optional shape, inventory-only flag.

Phase 1 does NOT move these rows. Phase 1 only DERIVES the core-class
assignment from the existing families (see H4), leaving ontology.ttl
byte-identical.

### H3.2 registry.ex (generated)

Becomes TWO generated artifacts from the same pack:

1. `lib/smalt/registry.ex` — dialect registry (unchanged in phase 1; phase 3
   regenerates from the dialect TTL instead of the control-plane rows). Carries
   `@admitted_resource_types`, `@type_shapes`, `@api_versions`,
   `admitted?/1`, `latest_version/1`, `admitted_version?/2`, ports.
2. NEW `lib/smalt/registry_core.ex` — core admission authority
   (LAYER 1). Carries the TOSCA-mapped core classes and their per-class
   capability facts (ports, capability-level invariants). `admits/2` over
   core-class IRIs; the monotonic version predicate moves here as
   `admits_version?(core_class, version)`; the dialect registry's
   `admitted_version?/2` becomes a delegation:
   `admits_version?(core_class_for(dialect_type), version)`.

Phase 1 adds `registry_core.ex` as a THIRD projection of the existing
ontology (deriving core classes from existing TypeBinding families); phase 3
flips the dialect artifact's source to the dialect TTL.

### H3.3 plug/common.ex

- `find_admitted/1` + `Registry.admitted?/1` — LAYER 2 (dialect string
  resolution). Stays byte-identical in phase 1.
- `check_version/3` — the wire gate. Structure unchanged; phase 3 swaps its
  internals to: resolve dialect type → core class (LAYER 2 mapping), then
  call the LAYER 1 `admits_version?(core, version)`. `check_api_version` is
  dialect data extraction (query param) and stays as the dialect gate called
  AFTER core-class admission. Note: today the order is inverted (dialect gate
  first, core admission implicit); the target ordering is core admission
  first, then dialect version gate — the phase-3 swap preserves observable
  behavior because unadmitted-dialect-type refusals have the same shape as
  today (400 InvalidApiVersionParameter under strict mode; permissive :ok
  otherwise).
- `version_base/1` and `version_lte?/2` — dialect version-syntax
  normalization (the `-preview` split, the `YYYY-MM → YYYY-MM-01` day-prefix
  normalization added for the ACR "2023-06-preview" case). Moves to the
  dialect layer (registry_core.ex keeps the monotonic Date comparison only).
  Phase 1: leave in place, mark with a `# DIALECT:` annotation.

## H4: Phase 1 — derive core classes FROM existing families, byte-identical

Phase 1's only write is a new template + query in the pack
(`registry_core.ex.eex`, `core_classes.rq`) plus the generated
`lib/smalt/registry_core.ex`. The `Microsoft.*` family → core class
derivation, from the current admitted surface:

| Core class (TOSCA-mapped) | Derived from existing families |
|---|---|
| `ObjectRegistry` | ContainerRegistry/registries(+webhooks), Storage storageAccounts family, Resources/resourceGroups |
| `ContainerWorkload` | App/containerApps, App/managedEnvironments, ContainerService/managedClusters, DevTestLab/schedules |
| `ComputeEnvironment` | Compute/virtualMachines, disks, diskEncryptionSets |
| `SecretStore` | KeyVault/vaults(+keys, secrets), managedHSMs |
| `DataStore` | DocumentDB/databaseAccounts family, OperationalInsights/workspaces |
| `MessageHub` | ServiceBus namespaces family, EventHub namespaces family, EventGrid topics/systemTopics family |
| `IdentityPrincipal` | ManagedIdentity/userAssignedIdentities(+federatedIdentityCredentials), federatedIdentityCredentials, Authorization roleAssignments/roleDefinitions |
| `NetworkFabric` | Network/* (vnet, subnet, nsg, nic, pep, pdz, pdzl, pip), publicIPAddresses |
| `TrustAnchor` | Attestation/attestationProviders, ConfidentialLedger/ledgers, managedCCFs |
| `GovernanceSurface` | Authorization/locks, policyExemptions, policyRemediations, policySetDefinitions, Insights/diagnosticSettings, dataCollectionRules, SecurityInsights/onboardingStates, Purview/accounts |

Every one of the 58 admitted types maps to exactly one core class; the
derivation is a query over existing rows, not a hand-list (the template
asserts total coverage: count(core-mapped types) == count(Registry.admitted
_resource_types/0), else generation fails loudly).

Non-goals in phase 1: no behavior change, no caller changes, no ontology.ttl
row moves. `plug/common.ex` untouched except the `# DIALECT:` annotations.

## H5: Phased close conditions

### Phase 1 (this lane's design target) — PARTIAL_ALIVE on close

- `mix smalt.gen` emits THREE artifacts; `lib/smalt/registry.ex` is
  byte-identical to pre-lane (replay identity fenced by
  Registry.ReplayIdentity; byte-identical replay gate must pass).
- `lib/smalt/registry_core.ex` exists, generated, and its coverage assertion
  holds: every `Registry.admitted_resource_types/0` entry resolves to exactly
  one core class.
- Full test census: exit 0, zero new failures vs pre-lane census
  (compile-abort ≠ failure count, reported separately).
- `plug/common.ex` diff is annotation-only (`# DIALECT:`
  markers on `check_version/3`, `version_base/1`, `version_lte?/2`).

### Phase 2 — ontology split lands

- `smalt-dialect-arm.ttl` exists; every `Microsoft.*` row in ontology.ttl is
  present in the dialect TTL with identical apiVersion/shape/inventory data.
  A pack verify script asserts set-equality (no row lost, none invented).
- ontology.ttl keeps the class hierarchy + core facts; dialect rows removed
  only after the set-equality court passes.
- registry.ex and registry_core.ex regenerate byte-identically against the
  split graph (same replay identity).

Both generated artifacts regenerate byte-identically from the split graph —
the phase-2 gate is a byte-identical replay of the phase-1 artifacts, not a
behavior test.

### Phase 3 — call-site flip

- `check_version/3` resolves dialect type → core class via the LAYER 2
  mapping, then LAYER 1 `admits_version?/2`. `find_admitted/1` stays as
  dialect-string resolution. `version_base/1`/`version_lte?/2` move to the
  dialect module.
- Falsifier gate: the shim-court that inserts an unadmitted dialect type
  (e.g. `Microsoft.Foo/bars`) and an over-latest version must produce the
  SAME wire refusal bodies as pre-flip (byte-identical error JSON) across the
  full router corpus; a flip that changes any wire body fails.
- Second dialect (e.g. AWS-shaped strings) must be addable as dialect TTL
  rows + one template pass with zero lib/smalt core edits — if a core class
  or registry_core.ex must change to add a dialect type, the split has
  failed (H5 falsifier for the whole design).

### Behavior-preservation gate (all phases)

`Registry.admitted?/1`, `latest_version/1`, `admitted_version?/2` outputs are
byte-identical across phases 1-3 for every input in the existing corpus
(probe receipts: all admitted types × admitted/refused/malformed versions ×
case-variant type strings, exercising find_admitted's downcasing).

## H6: Status

PARTIAL_ALIVE — design landed (this file); implementation phases 1-3 are
UNEXECUTED.

### H6.1 Phase-1 draft shard (lane M13, 2026-10-30)

- `docs/jira/v26.10.31/gaps/13-phase1-core-classes.ttl` — DRAFT layer-1
  core-class ttl, standards namespaces only (tosca:/cimi:/kmip:/sec:), zero
  wire strings / api-versions (excluded as dialect data per H1/H2). ALIVE:
  parsed with rdflib 7.6.0, exit 0, 64 triples.
- `docs/jira/v26.10.31/gaps/13-phase1-core-classes-notes.md` — projection
  table, mechanically derived from `lib/smalt/registry.ex`
  `@admitted_resource_types` (READ-ONLY). ALIVE: 57/57 mapped, exactly one
  core class each, count-verified by script (exit 0); zero UNSUPPORTED rows.
- **Census correction**: H4's "58 admitted types" is a stale receipt-cited
  count; disk enumerates **57**. Recorded as a typed correction in the notes
  file, never rounded.
- Proprietary-IRI falsifier: grep `smalt.dev|Microsoft/|azure` over the ttl
  -> 0 matches (exit 1 = clean).
- M2 consistency: `docs/jira/v26.10.31/gaps/02-p1-core-ttl-shard.md` present;
  namespace law and shape-class vocabulary (ResourceEnvelope/
  ConcurrencyLaw/EntryStatusLaw/OperationLifecycle) kept consistent via
  rdfs:seeAlso bindings.
- Open residual: **admission-corpus close condition BLOCKED-on-merge** —
  the phase-1 court (three-artifact `mix smalt.gen`, replay-identity fence,
  full census) runs post-merge; this shard is DRAFT input to lane 8, not
  admitted core semantics (v26.10.31 in transition).

Evidence read this session: ontology.ttl (1433 lines),
registry.ex (250 lines, generated), plug/common.ex:239-344
(check_api_version/check_version/version_base/normalize_base/find_admitted),
arm/resource_providers.ex:4164, arm_gateway/plug/resource_providers.ex
(Registry call sites), pack templates registry.ex.eex + queries/control_plane.rq.

### H6.2 Layer-1 merge into canonical ttl (wave-2 gap lane, 2026-10-30)

ALIVE — merged and falsifier-green this session.

- `priv/ontologies/public-cloud-core.ttl` now carries the LAYER-1 admission
  class taxonomy: `tosca:CoreCapability` root + the 10 core classes, appended
  after shape 9 (`tosca:ArmResourceIdentifierShape`). Draft shard namespaces
  ported to the canonical ones (port table inlined in the ttl header comment:
  tosca/1.1# -> tosca/ns/simple/yaml/1.3/; cimi/1# -> cimi/2/; kmip 1.4# ->
  v1.4#; sec 1.0# -> w3id security#). Zero duplicate IRIs with lane 8's nine
  shapes; the shard's local-name space was disjoint (re-checked at merge).
- Decision record inlined in the ttl: role assignments/definitions are ruled
  under `tosca:IdentityPrincipal` per the M13 notes' own disjoint-prefix
  argument (identity fabric vs governance guardrails).
- Cross-links per the notes' seeAlso bindings: ObjectRegistry ->
  ObjectStorageShape/ResourceGroupShape; SecretStore -> ManagedSecretShape/
  ManagedKeyShape; IdentityPrincipal -> AuthorizationShape/RoleDefinitionShape;
  ContainerWorkload -> ContainerApplicationShape/ContainerEnvironmentShape;
  CoreCapability -> ArmResourceIdentifierShape (cimi:Resource geometry) and
  forward-refs to the M2 shard vocabulary (ResourceEnvelope, ConcurrencyLaw,
  EntryStatusLaw, OperationLifecycle — land with the M2 shard merge).
- Falsifiers (all run this session, exact exits):
  - rdflib parse exit 0, **318 triples** post-merge.
  - Proprietary-IRI grep (`smalt.dev|smalt.io|Microsoft/|azure`): 0 matches,
    exit 1 = clean.
  - `python3 scripts/verify_public_cloud_ontology.py` exit 0 (VERDICT: ALIVE
    [GREEN], 9 shapes sh:closed, all PASS).
  - `grep -c "sh:closed"` = 9 (>= 9 law holds).
  - 57/57 coverage rerun: mechanically derived from
    `lib/smalt/registry.ex` (read-only), disjoint-prefix law, exactly one
    core class per type; all 10 per-class counts match the merged ttl's
    rdfs:comment citations; exit 0.
- Serialization note: lane 8's dual-sh:pattern fix (ResourceGroupShape
  dcterms:title, single collapsed pattern) was re-read on disk immediately
  before the merge Edit and confirmed landed; no edit conflict.
- M13's admission-corpus residual (three-artifact `mix smalt.gen`,
  replay-identity fence, full census) remains **BLOCKED-on-regen** — recorded,
  not forced; it is the phase-1 court and runs post-regen.
