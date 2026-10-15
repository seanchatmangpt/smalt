# Remaining Pack Integration Census

Covers every pack in `~/ggen-marketplace/packs` NOT owned by the 15 other
integration lanes (I1–I15) and not already integrated. As of 2026-10-14.

## Ground truth

- Total packs on disk: **327** (all with `pack.toml`)
- Covered by lanes I1–I15: **44** packs
- Already integrated: **7** (smalt-substrate, graphlaw-ash-capability, azure-terraform,
  ash-r2rml-paas, ash-r2rml-reactor-paas, ash-ex4pm-evidence, ex4pm-wasm4pm-bindings)
- Remaining classified here: **276**
- Verdicts: **20 INTEGRATED-CANDIDATE**, **2 DUPLICATE-OF**, **24 RUST-ONLY**,
  **230 NOT-APPLICABLE**

## Assumptions (flagged for lane owners)

- **I8 "semantic×3"** read as semantic-projection-pack, semantic-parts-pack,
  semantic-procedural-graph-pack + experience-projection-pack. If a different trio,
  swap this file's semantic-procedural-graph entry.
- **I10 "strata×6"** read as the roadmap-slice core S1–S7: strata-hash, strata-tx,
  strata-ledger, strata-store, strata-chain, strata-net. The 10 strata packs classified
  here as RUST-ONLY are the remainder; adjust with the I10 owner.
- **I11 "clap-noun-verb family"** read as all 11 `clap-noun-verb-*` packs
  (pack, schema, crate, routing, behavior, boundary, verification, telemetry, policies,
  autonomic, zeroconfig). `cnv-any-manifest-pack` is classified here as RUST-ONLY.

## Smalt seams referenced

`lib/smalt/`: registry.ex (ARM control-plane registry), arm_gateway/, auth/, security/,
data_plane/, messaging/ (AMQP/ServiceBus/EventHubs), ocel/, pplan/, dspy/, graphlaw/,
semantic/, store/, telemetry/, tls.ex, egress_router.ex; `bin/smalt` (smaltctl CLI);
`docs/ERROR_CODES.md`; `test/sdk-smoke/` (Node + Python Azure SDK smoke harnesses);
`mix smalt.gen` (ontology→registry projection).

## INTEGRATED-CANDIDATE (20)

Each: pack → smalt seam + one-line value.

| Pack | Seam | Value |
|---|---|---|
| adapter-family-matrix | `mix smalt.gen` projection / lib/smalt/semantic | RDF-driven N-subject×N-consumer adapter manufacture; generate per-provider registry/SDK adapter modules instead of hand-writing them |
| aloop-episode-ontology-pack | lib/smalt/ocel | ALOOP episode + OCEL 2.0 event/object vocabulary; instrument autonomous episodes as OCEL events smalt's OCEL surface already consumes |
| authzen-spiffe-absorption-pack | lib/smalt/auth + lib/smalt/security | AuthZEN/SPIFFE trust-domain vocabulary; ground smalt's local trust domain and authz decisions in a standard vocabulary |
| chicago-graphlaw-court-pack | lib/smalt/graphlaw | Chicago adversarial court suite over graphlaw law; gives smalt's graphlaw seam executable violation courts |
| cs2-semantic-work | lib/smalt/data_plane | Authority-free consumer projections incl. Elixir admission adapters; reuse for data-plane request admission shapes |
| dspy-pack | lib/smalt/dspy | Universal DSPy generation vocabulary (verified against dspy 3.1.3); law for the dspy seam smalt already ships |
| ex-noun-verb-cli-pack | bin/smalt (smaltctl) | ex_noun_verb_cli Elixir verb-noun CLI machinery; structure smaltctl commands as generated verb-noun surfaces |
| fortune5-deployment-blocks-pack | lib/smalt/arm_gateway + registry.ex | AWS/Azure/GCP deployment building blocks; Azure blocks feed additional ARM control-plane resource shapes |
| kubernetes-workload-pack | lib/smalt/registry.ex + arm_gateway | K8s workload resource vocabulary; extends the ARM registry toward AKS-class workload resource types |
| nist-zero-trust-agentic-data-pack | lib/smalt/security (+ docs/compliance) | NIST zero-trust agentic-data crosswalk; compliance profile for smalt's security surface |
| planning-federation-pack | lib/smalt/pplan | Planning-federation vocabulary (consumer+shapes); federate smalt's pplan across planner profiles |
| planning-policy-pack | lib/smalt/pplan | Canonical world-model/HDDL/FOND policy vocabulary; the law layer for smalt's pplan planner |
| process-intelligence-pack | lib/smalt/ocel | Event/object observation, conformance, drift vocabulary; upgrade the OCEL seam from log storage to conformance checking |
| refusal-vocabulary-pack | lib/smalt/arm_gateway (+ docs/ERROR_CODES.md) | Typed refusal vocabulary; align arm_gateway error bodies with canonical refusal classes |
| sa2a-chicago-court-pack | test/ (ExUnit court generation) | Generates ExUnit adversarial courts over real collaborators; smalt's own test discipline as generated capital |
| semantic-documentation-contract-pack | lib/smalt/semantic + docs/SEMANTIC_PROJECTION.md | Revision-bound doc projection contract; prose as non-sovereign projection of smalt's semantic surface |
| shacl-to-pydantic-pack | test/sdk-smoke (Python fixtures) | SHACL→pydantic projection; generate Python SDK smoke parity fixtures from registry shapes |
| shacl-to-zod-pack | test/sdk-smoke (JS fixtures) | SHACL→Zod projection; generate JS SDK smoke parity fixtures from registry shapes |
| toolchain-unify-pack | repo tooling (`.tool-versions`) | Canonical Elixir/Erlang `.tool-versions` from one RDF source; stops pin drift across smalt CI |
| workflow-corpus-pack | lib/smalt/pplan | Chicago-test fixture subjects for a capability-resolution engine; conformance corpus for smalt's pplan |

## DUPLICATE-OF (2)

Superseded variants retained as lifecycle husks; not integration targets.

| Pack | Superseded by / reason |
|---|---|
| ash-extension-core-pack | DUPLICATE-OF ash-extension-pack (I1) — explicitly consolidated, retained lifecycle-only |
| ash-extension-starter-pack | DUPLICATE-OF ash-extension-pack (I1) — composition-root over core-pack, superseded by the I1 canonical pack |

## RUST-ONLY (24)

No Elixir surface; smaltctl (`bin/smalt`)-family or toolchain candidates only.

| Pack | Reason |
|---|---|
| autofde-openclaw-bridge-cnv-pack | clap-noun-verb Rust CLI generator, autofde domain |
| autofde-sota-factory-cnv-pack | clap-noun-verb Rust CLI generator, autofde domain |
| cargo-cicd-pack | Cargo CI/CD templates; Rust toolchain surface |
| chicago-tdd-tools-pack | Rust TDD tooling crate family |
| cnv-any-manifest-pack | clap-noun-verb manifest consumer; Rust CLI family (see I11 assumption) |
| dsrust-pack | Rust-native counterpart of dspy-pack; if smalt's dspy seam grows a Rust guest, revisit |
| mcpp-pack | Rust MCP client/server; Rust-side pair of I15's Elixir MCP surface |
| rmcp-pack | Rust MCP SDK; same class as mcpp-pack |
| rust-doc-hdit-pack | Rust doc pipeline (ships Cargo.lock/src/target) |
| rust-wasi-wasmex-pack | Rust→WASM→Elixir pipeline; Elixir host half exists but kernel is Rust/WASM |
| star-toml-pack | Star-TOML Rust crate projections (API-fidelity target) |
| tcps-pack | TCPS no_std Rust crate family (consolidated) |
| tcps-release-pack | TCPS Rust release surface |
| wasi-json-abi-pack | WASI JSON-ABI FFI substrate (Rust/WASM; DEPRECATED.md present — verify before adoption) |
| strata-audit-pack | Rust audit runner over strata engines |
| strata-cas-pack | Rust content-addressed store (conceptually near lib/smalt/store, but projects Rust) |
| strata-consensus-pack | Rust consensus kernel |
| strata-governance-pack | Rust governance-diff gate |
| strata-pn64-pack | Rust PN64/OCEL64 ABI masks |
| strata-protocol-pack | Rust CLAP-PDU protocol types (if I10's six differ, this may move to covered) |
| strata-signer-pack | Rust detached-signature attestations |
| strata-stratus-pack | Rust witnessing valves |
| strata-temprun-pack | Rust fuel-leased actuation arena |
| strata-valve-pack | Rust refusal valves |

## NOT-APPLICABLE (230)

Domain mismatch, marketplace-internal, or no smalt seam. One-line reason each.

| Pack | Reason |
|---|---|
| a2a-conformance-pack | A2A v1.0 conformance machinery for ash_a2a; smalt ships no A2A surface |
| a2a-durability-pack | ash_a2a/ash_pplan task durability; smalt's pplan is a planner, not a task store |
| a2a-hex-migration-pack | Migrates hex :a2a → ash_a2a; no a2a dependency exists in smalt |
| agent-fleet-isolation-pack | ggen-sync fleet lane isolation; smalt runs no agent fleets |
| agent-harness-recompilation-pack | Harness-recompilation doctrine; no smalt seam |
| ai-chatbot-shadcn-pack | Next.js/shadcn frontend generation; no frontend in smalt |
| ash-ex4pm-evidence-pack | Already integrated (listed for completeness) |
| autofde-gymact-certification-pack | autofde/gymact certification domain |
| autofde-lab-gymact-bridge-pack | autofde/gymact bridge domain |
| autofde-lab-standing-vocabulary-pack | autofde standing vocabulary, lab domain |
| autofde-level4-actuation-pack | autofde actuation-level doctrine |
| autofde-semantic-registry-pack | autofde semantic registry, lab domain |
| automatic-autonomic-operations-pack | Autonomic-operations doctrine; no concrete smalt seam |
| beam-wasmex-host-pack | Generates Wasmex wasm hosts; smalt has no wasm engine |
| beam4pm-contracts-pack | beam4pm AI/MCP contract vocabulary, product domain |
| beam4pm-post-llm-runtime-pack | beam4pm runtime domain |
| beam4pm-pro-entitlement-pack | beam4pm Pro entitlements |
| beam4pm-pro-infra-pack | beam4pm Pro infrastructure |
| beam4pm-process-model-pack | beam4pm process model, product domain |
| beam4pm-wasm-engine-pack | beam4pm wasm engine domain |
| biblegym-pack | gymact bible-reading domain |
| candidate-admission-portfolio-pack | Portfolio admission doctrine, no smalt seam |
| capability-closure-pack | Marketplace capability closure solver; marketplace-internal |
| capability-ecology-pack | Runtime-family capability contracts for ash_pplan; marketplace-internal |
| capability-lineage-propagation-pack | Capability lineage governance; no smalt seam |
| castle-board-pack | Chatman castle release board |
| castle-changelog-release-pack | Castle changelog/release surface |
| certification-assist-evidence-control-pack | Certification evidence-control domain |
| certification-assist-pack | Certification-assist domain |
| challenger-value-framing-pack | Value-framing doctrine |
| chatgptgym-gymact-bridge-pack | gymact bridge domain |
| chatman-ecosystem-release-pack | Chatman ecosystem release machinery |
| chatman-ecosystem-v26-9-1-release-gate | Point-in-time release gate (v26.9.1) |
| chatman-marketplace-commerce-dod-pack | Marketplace commerce DoD |
| chatman-togaf-closure-pack | TOGAF closure for chatman ecosystem |
| chicago-xaas-surface-pack | XaaS surface generation, xaas domain |
| claude-code-pack | Generates Claude Code Workflow scripts; harness domain |
| claudecode-gymact-pack | gymact domain |
| closed-loop-option-capital-pack | Option-capital epistemic machinery |
| collective-skill-court-pack | Skill-court machinery, harness domain |
| composition-leverage-matrix-pack | Composition epistemic ledger machinery |
| composition-solver-pack | Composition solver, marketplace-internal |
| consequence-ir-pack | Consequence IR doctrine |
| consumer-realization-frontier-pack | Epistemic frontier machinery |
| control-plane-causality-observability-pack | Epistemic causality ledgers, not wire/control-plane observability |
| control-plane-invariants-pack | Multi-agent control-plane integrity gates for ggen sync; smalt control plane is ARM-shaped, not agent governance |
| counterfactual-frontier-replay-pack | Counterfactual replay epistemics |
| crown-conjecture-pack | Crown doctrine |
| cs2-canonical-pack | CS2 fleet canonical mappings, product domain |
| cs2-conformance-pack | CS2 conformance fixtures |
| cs2-exact-subject-pack | CS2 exact-subject machinery |
| cs2-fleet-contract | CS2 fleet contract, product domain |
| cyberpunk-tv-platform | Media platform domain |
| decision-optionality-pack | DfCM candidate-space vocabulary |
| delegation-admission-pack | Delegation/admission calculus (arXiv-grounded doctrine) |
| deterministic-dynamic-ui-pack | UI generation |
| deterministic-layout-pack | Layout generation |
| dfcm-pack | DfCM constitutional machinery |
| dflss-pack | DFLSS/DMEDI methodology pack |
| dogfood-lifecycle-pack | Dogfooding lifecycle hooks |
| domain-capability-pack | Capability/authority vocabulary for executable worlds |
| dry-run-publish-pack | Dry-run publish DoD case study |
| ecc-agent-harness-profile-pack | Agent-harness profile domain |
| economic-isa-dfcm-pack | Economic ISA doctrine |
| enterprise-architecture-connection-pack | EA connection vocabulary, EA domain |
| enterprise-architecture-pack | EA domain |
| enterprise-governance-pack | EA governance vocabulary, EA domain |
| enterprise-operating-model-pack | Operating-model strategy, EA domain |
| environment-evolution-pack | Environment-evolution contract, no smalt seam |
| epistemic-sensor-factory-pack | Epistemic R-lane sensor machinery |
| errc-ownership-manifest-pack | ERRC ownership accounting, marketplace-internal |
| evidence-capital-admission-pack | Evidence-capital governance (family of 7) |
| evidence-capital-control-policy-pack | Evidence-capital governance |
| evidence-capital-control-realization-pack | Evidence-capital governance |
| evidence-capital-policy-adaptive-control-pack | Evidence-capital governance |
| evidence-capital-policy-realization-pack | Evidence-capital governance |
| evidence-capital-realization-control-pack | Evidence-capital governance |
| evidence-capital-realization-pack | Evidence-capital governance |
| evidence-lineage-independence-pack | Evidence governance |
| evidence-standing-pack | Receipt/standing invariants, doctrine |
| evolvable-capability-pack | Capability lifecycle governance |
| external-paradigm-recompilation-pack | Doctrine machinery |
| fanout-realization-controller-pack | Fanout epistemic controller |
| fastmcp-pack | Python FastMCP server generation; smalt MCP surface owned by I15 (Elixir) |
| fde20-revops-pack | FDE revops domain |
| fleet-projection-closure | Fleet projection closure, product domain |
| forced-top25-pack | Forced-top25 consolidation machinery |
| fortune5-architecture-pack | Fortune-5 EA law, EA domain (deployment-blocks sibling is the actionable one) |
| fortune5-enterprise-architecture-pack | EA topology SBB domain |
| fortune5-testing-bblock-pack | EA testing building blocks, EA domain |
| frontier-derivative-pack | Epistemic frontier machinery |
| frontier-release-factory-pack | Release factory doctrine |
| gall-core-pack | Gall checkpoint/execution framework, ggen-ecosystem domain |
| gcp-marketplace-saas-pack | GCP marketplace SaaS; smalt is an Azure drop-in replacement |
| gdmcp-pack | Data-mcp product domain (no readable description; low-confidence NA) |
| ggen-combinatorial-maximalism-pack | ggen CMD constitution, marketplace-internal |
| ggen-constitution-pack | ggen constitution |
| ggen-ecosystem-ocel-pack | ggen-ecosystem receipt OCEL, marketplace-internal (not smalt's OCEL seam) |
| ggen-opportunity-hypergraph-pack | Opportunity hypergraph epistemics |
| ggen-pack-spec-pack | ggen pack spec, marketplace-internal |
| ggen-platform-pack | ggen platform machinery |
| ggen-project-boundary-pack | ggen project-boundary ledgers |
| ggen-release-pack | ggen release surface |
| ggen-self-host-pack | ggen self-host machinery |
| ggen-self-pack | ggen self-generation |
| ggen-verify-pack | ggen verify schema, marketplace-internal |
| gh-actions-errc-pack | GitHub Actions ERRC, repo-CI domain |
| gh-enterprise-architecture-pack | EA over GitHub, EA domain |
| gh-terraform-pack | Terraform GH workflows; azure-terraform (integrated) already owns smalt's Terraform trust story |
| github-actions-pack | Generic GitHub Actions generation; smalt integration is substrate features, not repo CI |
| github-controloutcome-observation-pack | Control-outcome observation epistemics |
| governance-gate-pack | Governance-gate doctrine |
| governed-runtime-adapter-pack | Governed-runtime evidence contract, doctrine |
| greene-licensing-case-pack | Licensing case study |
| gym-autonomic-crown-pack | gym-ecosystem crown |
| gym-ci-toolchain-bblock-pack | gym CI toolchain |
| gym-mcp-surface-pack | gym MCP surface, gym domain |
| gym-upper-ontology-pack | gym upper ontology |
| industry-closure-ledger-pack | Industry-closure calculus kernel, EA domain |
| industry-closure-retail-lending-profile-pack | Retail/mortgage-lending profile; domain mismatch (litigation-class vertical) |
| insa-law-pack | insa-law pinned vocabulary, no readable smalt seam |
| interchangeable-parts-qualification-pack | Parts-qualification doctrine |
| jotp-benchmark-site-shadcn-pack | Benchmark site frontend |
| kudzu-case-studies-pack | Identity-only integration catalog, not capital |
| lean-math-pack | Lean 4 ProcInt renderer, formal-math domain |
| level-five-book-pack | Book/doctrine artifact |
| lifegym-world-pack | gym world domain |
| live-data-polling-pack | Live-polling UI pack |
| lsp-max-pack | LSP tooling domain |
| ma-case-study-pack | Case-study fixtures |
| manufacturing-fanout-controller-pack | Fanout controller doctrine |
| marketplace-governance-pack | Marketplace governance, marketplace-internal |
| mdbook-pattern-language-pack | mdbook docs domain |
| mermaid-pack | Mermaid diagram generation |
| mfact-pack | mfact certification machinery |
| mfw-pack | mfw doctrine machinery |
| mfw-pcp-level5-pack | mfw Level-5 ledger |
| mmdio-pack | mmdio doctrine |
| multicell-consumer-factory-pack | Multicell consumer factory doctrine |
| neako-web-deckgl-pack | Deck.gl web frontend |
| nextjs-ai-sdk-pack | Next.js + AI SDK app generation |
| nextjs-ai-sdk-ui-shadcn-pack | Next.js UI generation |
| nist-cyber-resiliency-generational-pack | NIST 800-160 generational-remanufacture profile; compliance domain without a smalt seam (contrast nist-zero-trust) |
| ontostar-mustar-powlv2-agent-pack | POWL 2.0 agent, process-mining product domain |
| ops-dashboard-legend-pack | Dashboard legend UI |
| option-capital-recombination-pack | Option-capital machinery |
| orthogonal-consumer-capital-pack | Consumer-capital machinery |
| osx-clnr-pack | macOS disk-cleanup substrate, ops domain |
| owning-rail-observability-pack | Owning-rail epistemic observability |
| owning-rail-remediation-pack | Owning-rail remediation doctrine |
| owning-rail-remediation-counterfactual-pack | Owning-rail doctrine |
| owning-rail-remediation-counterfactual-realization-pack | Owning-rail doctrine |
| owning-rail-remediation-realization-pack | Owning-rail doctrine |
| pack-authoring-pack | Pack authoring, marketplace-internal |
| pack-compatibility-pack | Marketplace compatibility matrix, marketplace-internal |
| pack-consolidation-court-pack | Pack consolidation courts, marketplace-internal |
| pack-maturity-pack | Pack maturity promotion, marketplace-internal |
| platform-engineers-handbook | Handbook artifact |
| portable-consequence-protocol-pack | Consequence protocol doctrine |
| portfolio-epistemic-observability-pack | Epistemic portfolio observability |
| post-release-pack | Post-release publication packet |
| pptx-presentation-pack | PPTX generation |
| praxis-core-pack | praxis doctrine machinery |
| premature-actuation-survival-pack | Actuation-survival doctrine |
| prior-art-admission-pack | Prior-art admission doctrine |
| process-intelligence-rag-pack | PI RAG connection, RAG domain |
| process-mining-proof-pack | POWL/OCEL proof-test generation for the beam4pm pipeline |
| protocol-integration-pack | Adapter vocabulary without a concrete smalt transport target (egress_router has no consumer) |
| provider-extinction-contract-pack | Provider-extinction contract, doctrine |
| qri-consumer-binding-pack | QRI wasm interchange binding |
| qri-qualification-profile-pack | QRI wasm qualification profile |
| quadrature-pack | ProcInt release quadrature, formal-math domain |
| qualified-capability-ecology-pack | Capability-ecology doctrine |
| readme-diataxis-pack | README/Diataxis docs |
| receipt-provenance-unification-pack | gym receipt-schema unification, marketplace-internal |
| replication-epistemic-observability-pack | Epistemic replication observability |
| repo-as-found-pack | Repo governance |
| repo-intervention-pack | Repo governance |
| repo-load-path-pack | Repo governance |
| repo-reconciliation-pack | Repo governance |
| repository-factory-scheduler-pack | Repo governance |
| repository-lifecycle-pack | Repo lifecycle doctrine |
| repository-reconstitution-pack | Legacy reconstitution domain |
| revalidation-manufacturing-capital-pack | Revalidation machinery, doctrine |
| revenue-structural-option-factory-pack | Revenue option machinery, revops domain |
| run-protocol-observability-pack | Run-protocol epistemic observability |
| runtime-evidence-authenticity-pack | Runtime evidence doctrine |
| runtime-evidence-authenticity-control-pack | Runtime evidence doctrine |
| sa2a-bridge-pack | ggen_igniter bridge, marketplace-internal |
| sa2a-fastapi-pack | Python FastAPI surface, no smalt seam |
| sa2a-governed-process-pack | SA2A governed-process fabric, doctrine-heavy |
| sa2a-semantic-diataxis-pack | SA2A docs surface |
| sa2a-semantic-evidence-pack | SA2A evidence projections |
| sa2a-spark-dsl-pack | AshA2A-specific Spark DSL surface |
| self-monitoring-pack | Self-monitoring epistemic hooks |
| semantic-case-study-pack | Case-study fixtures |
| semantic-fullstack-factory-pack | Fullstack app generation |
| semantic-gate-witness-court-pack | Gate-witness courts, doctrine |
| semantic-manufacture-epoch-pack | Manufacture-epoch contract, doctrine |
| shacl-to-fastapi-pack | FastAPI target, no Python server in smalt |
| shacl-to-zod-jsdoc-pack | Zod+JSDoc variant; plain shacl-to-zod chosen for JS smoke fixtures |
| shadcn-ui-primitives-pack | UI primitives |
| sjira-marketplace-feedback-pack | SJIRA feedback, marketplace-internal |
| speedrun-talent-network-pack | Talent-network domain |
| standing-ladder-pack | Evidence-ladder doctrine |
| state-transition-pack | State-transition doctrine |
| strategic-doctrine-compiler-pack | Doctrine compiler |
| strategic-doctrine-pack | Doctrine machinery |
| supabase-pack | Supabase client wiring; smalt replaces the cloud, not a BaaS |
| supplier-equilibrium-pack | Supplier doctrine |
| supply-chain-evidence-pack | Supply-chain evidence doctrine |
| swarmsh-autonomic-coordination-pack | Swarm coordination doctrine |
| swe-prometheus-governance-pack | SWE governance retrofit, product domain |
| tcps-consumer-fanout-factory-pack | TCPS fanout doctrine, no Elixir surface |
| temporal-truth-observability-pack | Temporal-truth epistemics |
| temporary-works-pack | Temporary-works doctrine |
| togaf-adm-pack | TOGAF ADM case study, EA domain |
| tokyo-depeg-burn-in-pack | Flash-depeg trading burn-in, finance domain |
| value-innovation-errc-pack | ERRC doctrine |
| wasm4pm-algorithms-pack | wasm4pm product domain |
| wasm4pm-breed-provenance-pack | wasm4pm product domain |
| wasm4pm-cognition-pack | wasm4pm product domain |
| wasm4pm-compat-pack | wasm4pm product domain |
| wasm4pm-facts-pack | wasm4pm product domain |
| wasm4pm-interview-assist-pack | wasm4pm product domain |
| wasm4pm-pack | wasm4pm product domain |
| wd-failure-analysis-pack | Failure-analysis doctrine |
| ww3gym-planning-pack | gym planning domain |
| xaas-castle-bridge-pack | XaaS castle bridge, xaas domain |
| xaas-public-ontology-profile | XaaS public-ontology profiling, xaas domain (not smalt-substrate's Azure registry profile) |

## Reconciliation

20 + 2 + 24 + 230 = **276** remaining + 44 lane-covered + 7 already-integrated =
**327** = packs on disk. No pack listed twice.
