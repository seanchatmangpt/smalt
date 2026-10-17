# v26.10.16 — ash_kudzu ↔ smalt Full Integration Architecture

- **Status:** PLANNED (grounded in a read-only inventory of `~/ash_kudzu` @ `257589d`, 2026-10-07)
- **Premises corrected first:** the integration framing claims kudzu "defines Queues, Topics, Containers, Secrets as Ash resources" and "projects the exact ARM REST endpoints". The inventory finds **neither**: ash_kudzu contains **zero Ash resources in lib/** (only ETS test fixtures), **zero Spark DSL extensions**, and projects **RDF/Turtle + SA2A JSON evidence envelopes only** — no ARM routes, no AMQP frames, no wire shapes. It is a real but narrow **Ash→RDF/evidence compiler** (introspect → project → SHACL-admit → evidence), fully decoupled from smalt (zero cross-deps), and does not compile in this sandbox (no `deps/` fetched).

What it is: a ~1,200-LOC lib pipeline (1,199 LOC under `lib/`, plus a 652-LOC `.exs` test suite = 1,851 with tests) — `introspector.ex` (over the real `Ash.Resource.Info` reflection API), `ontology_projector.ex` (Turtle: owl:Class, kudzu:Action, Ash-type→XSD map), `shacl_admission.ex`, `openapi_extractor.ex` (OpenAPI 3.x → introspector shape), `sa2a_candidate.ex` / `sa2a_evidence_admission.ex` (portable evidence envelopes, RDFC-1.0, sha256 chains, honest `authority: "NONE"` / `EVIDENCE_ONLY`), plus ggen charter-pack manifests and SHACL shapes.

## The real integration story

The declarative-grammar contribution kudzu can make to smalt is **derivation of the registry, not the wire**. smalt's ARM surface today is hand-maintained: `Smalt.Registry` (38 admitted types + `type_shapes` + `api_versions` as static module attributes) and hand-coded routes in `ArmGateway.Router`. The integration makes that surface *derived from declarative Ash resources*, with kudzu's proven pipeline generating the ontology + evidence metadata from them.

### Stage 1 — Author the declarative entities (smalt-side, net-new)
Model the core ARM entities as Ash resources living in smalt: `ServiceBus.Namespace`, `ServiceBus.Queue`, `ServiceBus.Topic`, `ServiceBus.Subscription`, `Blob.Container`, `Cosmos.Database`/`Container`, `KeyVault.Key` — actions mirroring the admitted verbs (create/read/replace/delete + the azapi actions), validations lifted from the existing GraphLaw shapes (the 38 admitted types' required-property rules are already pinned in `Validator.shapes()` — the resource validations are a re-expression, not new semantics).

### Stage 2 — Store-backed data layer (smalt-side, precedent exists)
Back the resources with `Ash.DataLayer.Simple` reading `Smalt.Store` views first (precedent: three revops modules already do `Simple` + `set_data/2` over ETS (`ocel_trace.ex`, `fitness_verdict.ex`, `ocel_deviation.ex`, e.g. `ocel_trace.ex:42`)); graduate to a thin custom `Ash.DataLayer` over the ordered_set tables only when filter/pagination demands it. kudzu's own fixtures prove the ETS pattern. The wire substrate (router → Store) does not move — resources are the *modeling* layer above it.

### Stage 3 — Run the kudzu pipeline over them (kudzu-side, exists)
`AshKudzu.Introspector.introspect_resource/1` → `ontology_projector` → `shacl_admission` → Turtle + SA2A evidence envelopes. This replaces hand-maintained registry *provenance* with derived artifacts: the 38 admitted types' ontology, action inventories, and capability-candidate envelopes become generated, digest-chained, and SHACL-admitted. Add the one missing projector as net-new kudzu work: an **ARM-shape projector** (registry `type_shapes` + route table → the same Turtle/envelope targets), since kudzu emits no wire formats today.

### Stage 4 — Derive the registry (the actual work)
`Smalt.Registry`'s admitted-types/shapes/api-versions become a **generated projection** of the Stage-1 resources (compile-time introspection or a `mix ash_kudzu.derive_registry` task writing the module), with the existing registry fence tests (`smalt_registry_replay_identity_test.exs` class) pinning derived == pinned during migration. This is where the drift class dies: today a new resource type means hand-editing registry + shapes + router + docs; after, it means authoring one resource and regenerating.

## Explicit non-goals / honest gaps

- **No wire generation from Ash** in this window: the routers stay hand-coded (they carry mutation courts, wire-parity pins, and fail-closed laws that a generated router would have to re-earn). Stage 4 derives *registry data*, not routes.
- **No authorization mapping**: kudzu emits `authority: "NONE"` / `EVIDENCE_ONLY` by design; the bearer fence stays entirely smalt-side. Ash policies on the resources are future work and must map to the existing Bearer/STS fence, not bypass it.
- **kudzu sandbox-blocked**: no `deps/` fetched; compile/test must be re-verified in a networked environment before Stage 3.
- **The cross-partition/transactional-batch and lease gaps** (A-3, A-2 findings) are wire-layer work independent of this integration.

## Falsifier for the window

After Stage 4: delete one resource's registry entry by hand → the derive task regenerates it (drift dies); corrupt a projected Turtle → SHACL admission refuses it (the existing gate fires); the 38-type registry fence tests pass unchanged against the derived module.

## Sequencing

Stage 1+2 (smalt-side) → Stage 3 (kudzu-side, needs networked deps) → Stage 4 (the derivation). Each stage lands independently with its own courts; Stage 4 is the only stage that touches the hot path, and it lands behind the existing registry fence tests.
