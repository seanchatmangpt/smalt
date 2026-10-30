# 11 — Consolidation Annexes: Credential Model + Admission Split

Status: PARTIAL_ALIVE — annexes cite and summarize landed lane designs; no code changed.
Reconciled 2026-10-30 against the now-ALIVE neutral model spec
(`docs/jira/v26.10.31/gaps/09-credential-core-model.md`, authoritative for
Annex A vocabulary) — see "Reconciliation vs model spec (2026-10-30)" at the
end of Annex A.
Subject (sources as-of their own receipts):
- Annex A source: `/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/09-credential-model.md`
  (smalt @ f0e0a12, courtroom-platform-az @ 31c58e9 working tree; lane 9 PARTIAL,
  census ALIVE, spec-only phase 1 DONE).
- Annex B source: `/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/13-admission-split.md`
  (lane 13 of 17, design PARTIAL_ALIVE, phases 1-3 UNEXECUTED).

This lane consolidates both designs as charter annexes. The full designs — file
censuses, phase close conditions, derivation tables — live in the source files and
are NOT restated here; these annexes carry the load-bearing vocabulary, invariants,
and open items so downstream lanes cite one location.

## Annex A — Neutral Credential Model (M9)

Source: `docs/jira/posh/v26.10.31/gaps/09-credential-model.md` §1-2 (model +
mapper), §3 (census), §4 (phase gates).

Core vocabulary: every Azure-shaped credential request minted today by harnesses,
CLIs, the TF provider, and verification harnesses is a *dialect rendering*, not
the model. The neutral core is:

- `CredentialRequest{principal, factor, audience}`
  - `principal`: `{kind: :client, id: PrincipalId}`; `PrincipalId` opaque,
    dialect maps to native form (today: zero-guid `client_id`).
  - `factor`: `{kind: :shared_secret, ref: SecretRef}`;
    `SecretRef :: {:env, name} | {:file, path} | {:literal, v}` (literal =
    dev only). Core carries the *reference*; dialect resolves the value to
    wire form (client_secret form field, header, ...).
  - `audience`: `Scope :: :control_plane | {:data_plane, resource} |
    {:dialect, dialect_name, native_scope}`. Azure's
    `https://management.azure.com/.default` is the azurerm-dialect *rendering*
    of `:control_plane`; data-plane scopes render per-resource.
- `tenant`: opaque core authority-namespace key; `tid` is a dialect claim
  rendering. Canonical env is `SMALT_TENANT_ID`; `ARM_*` are dialect aliases.
- Issuer: neutral via `config :smalt, :issuer_host` (already exists,
  `lib/smalt/arm_gateway/plug/oidc_sts.ex`); the zero-guid claims are dialect
  token rendering, not core identity.

Per-dialect mapper — `Smalt.Cred.Dialect` behaviour, 3 callbacks:

- `to_wire(CredentialRequest)` — dialect-shaped token HTTP request.
- `from_claim(token)` — verify-side: core `Principal` + `Scope`.
- `scope_binding(core_scope)` — dialect native scope string.

New dialect = one new mapper module + scope binding, zero core change.

### Key invariants

- Core carries SecretRef, never the secret value; only dialects resolve it.
- `:control_plane` is the default core scope; the Azure management scope string
  is azurerm-dialect data, not core vocabulary.
- The smalt STS face (`oidc_sts.ex`) STAYS Azure-shaped as dialect-1 wire
  compat until face inversion (phase 3); existing Azure-shape tests stay as
  dialect-1 compat tests, neutral-core tests are added, never mutated.
- Dialect-1 wire must be reproduced byte-identically by the azurerm mapper
  (court asserts byte-identical STS response over a recorded request corpus).
- New-dialect falsifier: a second dialect mints + verifies with ZERO change to
  `oidc_sts.ex`.
- Census is classified, not estimated: smalt ~260 non-docs + 718 docs hit-files;
  courtroom-platform-az 12 files, every row P2 (phase-2 dialect extraction) or
  STAYS (dialect-1 compat / egress-canary). Egress canaries
  (`hermetic.test.ts`, `hermetic_guard.sh`) cite the Azure scope string as the
  "outside", not as a credential — STAYS.
- Phase 1 close is spec-only: census complete, every hit classified, zero code
  changed (DONE per source receipt).

### Open items

- Phases 2-3 UNEXECUTED: `Smalt.Cred.Core` / `Smalt.Cred.Dialect` /
  `Smalt.Cred.Dialect.Azure` do not exist yet; no P2 consumer re-pointed.
- TS twins (`credential.ts`, `smalt-client.ts` harness factories) still
  hardcode zero-guid/secret/scope literals pending the factory param.
- Hermetic-guard allowlist needs a disclosed diff when the mapper module lands.
- Face inversion (phase 3: neutral wire, ARM_* as aliases, C1/C6 docs
  neutral-first) explicitly out of scope of lane 9.

### Reconciliation vs model spec (2026-10-30, fresh grep this session)

Authoritative vocabulary: `docs/jira/v26.10.31/gaps/09-credential-core-model.md`
(ALIVE, @ smalt f0e0a125 / platform-az 31c58e91 — same HEADs as this annex).
Downstream lanes cite the SPEC's terms, not this annex's paraphrase:

- SATISFIED (in substance) — core vocabulary, SecretRef-not-value law,
  `:control_plane` default, zero-guid as dialect rendering, issuer via
  `config :smalt, :issuer_host` (verified `lib/smalt/arm_gateway/plug/oidc_sts.ex:183`),
  dialect behaviour with 3 callbacks (spec names it `DialectMapper`;
  this annex's `factor` field renders as spec's `auth_factor`, and spec's
  `to_wire` takes `(CredentialRequest, wire_ctx)`).
- CONTRADICTED — census counts (annex: "smalt ~260 non-docs + 718 docs;
  platform-az 12 files"). Fresh re-run of the spec's grep disjunction:
  smalt non-docs = **108**; platform-az = **18** files (ts/sh/yml/md,
  node_modules excluded) — both match spec §2. The annex's ~260/718/12
  figures are stale census-draft numbers; do not cite them.
- SATISFIED (still open, confirmed fresh) — open items verified current:
  no `lib/smalt/cred/` dir and no `Smalt.Cred` grep hits (phases 2-3
  unexecuted); TS twins still hardcode zero-guid/secret/scope literals
  (platform-az `apps/web/test/harness/lib/smalt-client.ts:17,19`,
  `apps/web/test/harness/vault/lib.ts:7-8,50,52`,
  `apps/web/test/harness/nfr/cleanup.test.ts:18`); egress canaries live in
  courtroom-platform-az (`scripts/hermetic_guard.sh:11,37`,
  `apps/web/test/harness/nfr/hermetic.test.ts`), STAYS per annex.
- OPEN — `SMALT_TENANT_ID` canonical env key is spec vocabulary only:
  zero grep hits under smalt lib/config/verification/smalt-cli/workspace
  (2026-10-30); lands with phase 2/3.
- Minor line drift vs spec §2 (content present, rows stand):
  `bearer.ex` `# KD-COVERS: KD-15` at :690, `challenge_value/2` :710,
  `send_challenge` :738 (spec cites :692/:695-720/:734-745);
  `credential.ts` scope default at :27 (spec cites :30).

## Annex B — Two-Layer Admission Split (M13)

Source: `docs/jira/posh/v26.10.31/gaps/13-admission-split.md` H1-H6.

Problem: admission conflates three concerns in one ontology +
one generated artifact — (1) abstract core classes (dialect-neutral), (2) ARM
wire strings (dialect data), (3) api-version lattices (dialect versioning) — all
in `smalt-substrate-pack/ontology.ttl` projecting into one
`lib/smalt/registry.ex`.

Split:

- **Layer 1 (core, admission authority)**: TOSCA-mapped core classes —
  `ObjectRegistry`, `ComputeEnvironment`, `SecretStore`, `MessageHub`,
  `IdentityPrincipal`, `ContainerWorkload`, `NetworkFabric`, `DataStore`,
  `TrustAnchor`, `GovernanceSurface` — stay in `ontology.ttl`.
- **Layer 2 (dialect projections, GENERATED)**: new `smalt-dialect-arm.ttl`
  binds each `Microsoft.*` wire string to a core class (58 admitted + 4
  inventory-only types; wire string, core-class IRI, apiVersion lattice top,
  optional shape, inventory-only flag).
- **Generated pair**: `lib/smalt/registry.ex` (dialect registry:
  `@admitted_resource_types`, `@type_shapes`, `@api_versions`,
  `admitted?/1`, `latest_version/1`, `admitted_version?/2`) + NEW
  `lib/smalt/registry_core.ex` (core authority: `admits/2` over core IRIs,
  monotonic `admits_version?(core_class, version)`; the dialect registry's
  `admitted_version?/2` becomes a delegation through
  `core_class_for(dialect_type)`).
- **Gate ordering (phase 3)**: `check_version/3` resolves dialect type → core
  class (layer 2), then layer 1 `admits_version?/2`. Today the order is
  inverted (dialect gate first); the swap preserves observable refusal shapes
  (400 InvalidApiVersionParameter strict-mode / permissive :ok).
- **Dialect version syntax**: `version_base/1` (incl. `YYYY-MM → YYYY-MM-01`
  day-prefix normalization for the ACR case) and `version_lte?/2` move to the
  dialect layer; `registry_core.ex` keeps only monotonic Date comparison.
- Phase 1 derivation: core-class assignment is a QUERY over existing
  TypeBinding families (source H4 table), not a hand-list; generation fails
  loudly unless every one of the 58 admitted types maps to exactly one core
  class (`count(core-mapped) == count(Registry.admitted_resource_types/0)`).

### Key invariants

- Adding a second dialect must never touch layer 1: a dialect = TTL rows + one
  template pass, zero `lib/smalt` core edits. If `registry_core.ex` must change
  to add a dialect type, the split has failed (H5 design falsifier).
- Phase 1 adds `registry_core.ex` as a third projection of the UNCHANGED
  graph: `ontology.ttl` byte-identical, `registry.ex` byte-identical
  (replay identity fenced by Registry.ReplayIdentity; byte-identical replay
  gate must pass), `plug/common.ex` diff annotation-only (`# DIALECT:` markers
  on `check_version/3`, `version_base/1`, `version_lte?/2`).
- Phase 2 gate is set-equality of dialect rows between `ontology.ttl` and
  `smalt-dialect-arm.ttl` (no row lost, none invented, identical
  apiVersion/shape/inventory data), then byte-identical regeneration of BOTH
  artifacts from the split graph — a replay gate, not a behavior test.
- Phase 3 falsifier gate: shim-court inserting an unadmitted dialect type
  (`Microsoft.Foo/bars`) and an over-latest version must produce byte-identical
  wire refusal bodies across the full router corpus; any changed body fails.
- Behavior-preservation gate spans all phases: `admitted?/1`, `latest_version/1`,
  `admitted_version?/2` outputs byte-identical for every corpus input
  (admitted types x admitted/refused/malformed versions x case variants,
  exercising `find_admitted/1` downcasing).
- Full test census per phase: exit 0, zero new failures vs pre-lane; compile-
  abort reported separately, never counted as failures.

### Open items

- Phases 1-3 all UNEXECUTED (source H6: design PARTIAL_ALIVE only). Phase 1
  deliverables (`registry_core.ex.eex` + `core_classes.rq` + generated
  `registry_core.ex`) do not exist yet.
- Core-class re-parenting of the `smalt:ControlPlane`/`DataPlane`/
  `MessagingBroker` hierarchy (ontology.ttl lines 14-47) is deferred to
  phase 2.
- `check_api_version` remains the dialect query-param gate called AFTER core
  admission once the phase-3 ordering flip lands; the flip's behavioral-
  equivalence argument rests on refusal-shape identity and is court-verified,
  not assumed.
- Cross-annex dependency: Annex B's dialect layer and Annex A's azurerm mapper
  both consume the same "dialect" concept; the credential mapper (A) and the
  type-mapping TTL (B) should be reconciled when either phase 2 lands.

### Reconciliation vs disk (2026-10-30, fresh grep this session)

- SATISFIED — `lib/smalt/registry.ex` exists (auto-projected, header cites
  `smalt-substrate-pack/ontology.ttl`; `@admitted_resource_types` at :18,
  `admitted?/1` :211, ReplayIdentity fence noted at :15); `check_version/3`
  (:283), `version_lte?/2` (:322), `version_base` in
  `lib/smalt/arm_gateway/plug/common.ex`; ontology hierarchy
  `smalt:ControlPlane`/`DataPlane`/`MessagingBroker` confirmed in the
  lines 14-47 block. NOTE: `smalt-substrate-pack/ontology.ttl` lives in the
  SIBLING repo checkout `/Users/sac/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl`
  — not under `/Users/sac/smalt/ggen-marketplace/` (which holds only
  `packs/posh`). Annex B paths are cross-repo; cite the absolute path.
- STILL OPEN (confirmed absent 2026-10-30) — `lib/smalt/registry_core.ex`
  and `smalt-dialect-arm.ttl` do not exist anywhere under /Users/sac/smalt
  (find over *.ttl: only mcp/semconv models); phases 1-3 remain unexecuted.
