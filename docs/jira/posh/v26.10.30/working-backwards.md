# Working Backwards: Smalt with POSH (Port In, Starboard Out)
Product Definition, Press Release & Executive FAQ
Document Status: Approved for Synthesis
Codename: Smalt-PISO (Sovereign Azure Substrate with POSH Asymmetric Highway)
Target Repositories: ~/smalt, ~/cai/courtroom-platform-az
Distribution Date: October 30, 2026

(Operator-supplied, authoritative. Full text preserved verbatim in this file
as the synthesis contract for POSH implementation.)

> **DIALECT-SCOPED** — this file's press-release claims are dialect-scoped
> (see note below). **Dialect scoping note (v26.10.31)** — added by GAP-15 wave-2 doc migration
> (lane 15). Decision record:
> [`../v26.10.31/00-unification-dialect-decision.md`](../v26.10.31/00-unification-dialect-decision.md).
> The press-release claims below are **dialect-#1-scoped** (the azurerm swap:
> "wire-accurate Azure ARM emulation", unmodified azurerm Terraform stacks,
> terraform apply < 2s) and **dialect-#0-scoped** (the Entra STS face:
> "mirroring Azure AD v2.0 endpoints"). They are not smalt-core claims:
> smalt-core is a vendor-neutral public-cloud ontology; vendor dialects live
> in posh. Core-level equivalents are v26.10.31 charter items
> (`../../v26.10.31/00-charter.md`, when landed) — the operator-supplied text
> below stays verbatim, never edited.

## Canonical code layout (from Internal FAQ Q1)

~/smalt/
├── ggen-marketplace/packs/posh/       # RDF models & ggen synthesis templates
│   ├── ontology/posh.ttl              # Core Ingress/Egress/Turnstile ontology
│   └── templates/                     # Elixir and Go code-generation templates
├── lib/smalt/
│   ├── arm_gateway/                   # Azure ARM REST routers & STS token authority
│   └── posh/                          # Core BEAM POSH Engine
│       ├── ingress/                   # Port In: Admission policies, SHACL validators
│       ├── egress/                    # Starboard Out: Zero-copy delivery, BLAKE3 receipts
│       └── supervisor.ex              # OTP supervision tree isolating ingress from egress
├── adapters/terraform-provider-smalt/ # Stateless Go provider shim (dev_overrides)
├── gates/                             # DfLSS and cleanroom verification gates
└── justfile.d/58-posh.just            # Orchestration targets: generate, build, court

## Press release (abridged — full original text supplied by operator 2026-10-30)

- GA announcement: Smalt + POSH — wire-accurate Azure ARM emulation on local
  silicon (Apple Silicon/Linux/kind), unmodified azurerm Terraform stacks,
  microsecond latencies, zero egress.
- Tri-tier: BEAM sovereign ARM control plane; POSH asymmetric highway
  (ingress/ Port In SHACL-governed admission; egress/ Starboard Out zero-copy
  conduit); invisible Terraform swap via Go peripheral membrane
  (terraform-provider-smalt + dev_overrides, byte-identical HCL, no registry
  calls, no external state locking); cryptographic turnstiles emitting 32-byte
  BLAKE3 Merkle receipts (FDA 21 CFR Part 11, EU AI Act).
- Claims to hold us to: terraform apply < 2s locally (vs ~15min Azure);
  six-sigma reliability; validation in courtroom-platform-az.

## Engineering FAQ anchors

- STS: in-memory Security Token Service mirroring Azure AD v2.0 endpoints
  (POST /{tenant}/oauth2/v2.0/token, client_credentials -> valid mock bearer).
- Receipt: R_turnstile = BLAKE3(InboundDelta || NodeID || Timestamp_ns ||
  StateRoot), emitted as X-Smalt-Receipt-Turnstile header + append-only event
  log. HONEST CAVEAT (2026-10-30, G26, see
  gaps/26-turnstile-live-path.md): today the receipt is a live STAMP only
  (X-Smalt-Receipt-Turnstile header on every gateway response); the receipt
  FENCE — refusing an unreceipted delta and settling into the event log — is
  enforced nowhere live until lane 39 lands. Statement 6's "no unreceipted
  delta admitted" is a design requirement, not a current guarantee.
- Turtle over YAML: SPARQL invariant queries in CI prove every route terminates
  in an authorized turnstile; ggen SPARQL CONSTRUCT compiles graphs to Elixir
  GenStage pipelines + Go structs (0 DPMO by construction).
- Verification ladder via just posh-court: cluster boot (colima, 3-node kind,
  NodePort 30943 -> localhost:9443); health assert /metadata/endpoints 200
  (readiness anchor; /healthz is bearer-gated 401); provider build
  (transient TF_CLI_CONFIG_FILE dev_overrides hashicorp/azurerm); terraform
  apply of real platform HCL (courtroom-platform-az/infra/); Falsifier 1
  (STS-bearer wire inspection + destroy + zero residue); Falsifier 2
  (plan -detailed-exitcode = 0).
