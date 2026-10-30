# 09 — Neutral Credential Model + Azure Dialect Extraction (Migration Lane 9)

Status: ALIVE — phase 1 CLOSED (census + neutral core model spec, zero code,
lane M9); **phase-2 (a) STARTED 2026-10-30 wave-2 lane g09**:
`Smalt.Cred.Core` (`lib/smalt/cred/core.ex`, vendor-neutral — grep 0 hits)
+ `Smalt.Cred.Dialect.Azure` (`lib/smalt/cred/dialect/azure.ex`) +
court `test/smalt/cred/core_court_test.exs` (11 passed, exit 0; KD-15 flow
through Core+Mapper matches the real `Smalt.Auth.Bearer` challenge grammar;
wrong-audience mutation refuses typed). Phases 2(b)-(e) — consumer re-pointing,
recorded-corpus byte-identical STS court, second-dialect court, hermetic-guard
allowlist diff — remain OPEN.
Subject: smalt @ f0e0a12575c38f07e37a40ed58f4e448086c97b3, courtroom-platform-az @ 31c58e9 (working tree).
Lane scope: lane M9 wrote this file + the spec file; no code.

## 1. NEUTRAL core credential model (dialect-agnostic)

The Azure-shaped request that every harness, CLI, TF provider, and verification
harness mints today is a *dialect*, not the model. Core vocabulary:

```
CredentialRequest  :: {
  principal:    { kind: :client, id: PrincipalId }        // today: zero-guid client_id
  auth factor:  { kind: :shared_secret, ref: SecretRef }  // today: "smalt-sovereign-mock-secret"
  audience:     Scope                                     // today: "https://management.azure.com/.default"
}
Scope            :: :control_plane | {:data_plane, resource} | {:dialect, dialect_name, native_scope}
SecretRef        :: {:env, name} | {:file, path} | {:literal, v}  // literal = dev only
PrincipalId      :: opaque, dialect maps it to its native form
```

- **Issuer (neutral)**: `config :smalt, :issuer_host` — already exists
  (smalt lib/smalt/arm_gateway/plug/oidc_sts.ex, Lane R9 comment). The neutral
  issuer is the configured authority, not the request-derived loopback.
- **Subject**: claim `sub`/`oid` maps to core `PrincipalId`; today constants in
  oidc_sts.ex:145-148. In core terms the mint sets `principal.id` — the zero
  GUIDs are Azure-dialect token-claims rendering, not core identity.
- **Scope in core vocabulary**: control-plane scope is the default ("can act on
  the tenant's control plane"). Azure's `https://management.azure.com/.default`
  is the azurerm-dialect *rendering* of `:control_plane`. Data-plane scopes
  ({:data_plane, resource}) render per-resource in Azure dialect as
  `https://<resource>/.default`. `:dialect` scope is passthrough for
  dialect-native tokens (e.g. real Azure if a dialect targets it).
- **Secret reference, not secret value**: core carries a SecretRef; the
  dialect mapper resolves it to whatever the wire wants (Azure client_secret
  form field, header, etc.). `smalt-sovereign-mock-secret` /
  `smalt-tf-mock-secret` are dev-only SecretRef literals; core carries the
  SecretRef, the dialect resolves it.
- **Tenant**: core `tenant` is an opaque authority-namespace key. `tid`
  claim renders it dialect-side. `SMALT_TENANT_ID`/`ARM_TENANT_ID` are env
  renderings of the same core tenant key; core config reads ONE canonical env
  (`SMALT_TENANT_ID`) and dialects may accept their legacy aliases.

## 2. Per-dialect credential mappers

```
DialectMapper (behaviour, 3 callbacks):
  to_wire(CredentialRequest) -> token HTTP request (dialect-shaped)
  from_claim(token) -> core Principal + Scope      // verify-side mapping
  scope_binding(core_scope) -> dialect native scope string
```

- **azurerm dialect (dialect-1)**: `to_wire` produces exactly today's wire —
  POST {SMALT_ARM_ENDPOINT}/smalt/oauth2/v2.0/token, form-encoded client_credentials,
  zero-guid client_id + client_secret, scope `https://reuse...management.azure.com/.default` —
  for the STS face at oidc_sts.ex. The STS face keeps accepting Azure-shaped
  requests as dialect-1 wire compat until the face inverts.
  `SmaltTokenCredential` in both repos' harnesses is the TS-side of this mapper
  (today hardcoded; phase 2 extracts into it).
- **future dialects**: a `gcp`/`aws`/`native-smalt` dialect implements the same
  3 callbacks; core STS mints the same claims; only `to_wire`/`from_claim`
  differ. New dialect = new mapper module + scope_binding, zero core change.
- **verify side**: `Smalt.Auth.Bearer` verifies aud/iss/tid today; phase 2 it
  verifies against the *core* audience register (control-plane + data-plane
  scopes), with azurerm mapper translating to `https://management.azure.com`
  for dialect-1 compat.

## 3. Full file census, classified

Greps run this session over both repos (management.azure.com | sovereign-mock-secret |
oauth2/v2.0/token | ARM_* / SMALT_TENANT_ID | zero-guid 00000000-0000), excluding
node_modules/_build/deps. Class key: **P2** = changes-in-phase-2 (dialect
extraction), **STAYS** = the smalt STS face keeps accepting Azure-shaped
requests as dialect-1 wire compat.

### 3.1 smalt repo (/Users/sac/smalt @ f0e0a12)

**Core face — STAYS (dialect-1 wire compat, until face inversion):**
- lib/smalt/arm_gateway/plug/oidc_sts.ex — the STS face itself (mint, zero-guid
  appid/azp/oid/sub claims, Azure audience/scope rendering). STAYS until face
  inversion; when the core model lands it becomes the azurerm dialect-1 face
  backed by the neutral core (issuer_host already neutral).
- lib/smalt/arm_gateway/plug/metadata.ex (OIDC discovery rendering Azure audiences) — STAYS
- lib/smalt/auth/bearer.ex (default audiences incl. management.azure.com) — STAYS
  (becomes core audience register + azurerm translation in phase 2 backend,
  wire unchanged)
- config/config.exs:62 `token_audiences` — STAYS (dialect-1 default)
- lib/smalt/config.ex:544,735 — STAYS
- lib/smalt/auth/imds.ex, auth/tenant_law.ex, identity/oidc_idp.ex,
  plane/identity/sts_gate.ex — Azure-shaped identity-plane face; STAYS.
  Phase 2 moves their *decision core* into a neutral
  Smalt.Auth.Core (issuer/subject/scope/SecretRef resolution) so oidc_sts.ex
  and oidc_idp.ex become thin dialect faces.

Phase 2 mechanics (context for the P2 classes below): introduce
`Smalt.Cred.Core` (PrincipalId/Scope/SecretRef + issuer/tenant),
`Smalt.Cred.Dialect` behaviour (to_wire/from_claim/scope_binding), module
`Smalt.Cred.Dialect.Azure` (wraps the existing paths above), and re-point
consumers.

**Consumers that hardcode dialect (P2 — dialect extraction):**
- verification/ts/harness/credential.ts, verification/py/harness/credential.py —
  hardcode TENANT/CLIENT zero-guid, SECRET, management.azure.com scope. P2:
  read from a dialect-agnostic factory param, azurerm mapper supplies Azure
  shape. `SmaltTokenCredential` becomes the azurerm mapper's TS twin.
  `SUB` non-zero-guid workaround (11111111-…) documents an Azure-SDK
  client-side validation — that's dialect behavior, stays as azurerm-dialect
  note.
- smalt-cli/smalt_cli/gateway/sts.py, config.py, profile.py, wire.py — P2
- adapters/terraform-provider-smalt/internal/provider/server.go (ARM_SUBSCRIPTION_ID) — P2
- examples/*, scripts/stress/*, scripts/bench/*, popcorn_demo, workspace/lib/azure/*,
  ggen-marketplace/packs/posh/generated/*, posh pipeline generated (arm-*.ex):
  all *consumers* that mint Azure-shaped token requests or hardcode the Azure
  scope string. P2 — re-point to the cred factory/dialect mapper. Regenerated
  files (ggen arm-*.ex) change at the template, not the generated output.
- scripts/lib/substrate_boot.sh, scripts/substrate.sh, scripts/tf_*,
  scripts/bench/lib.sh — P2 (env var indirection exists; they pass SMALT_ARM_ENDPOINT
  through; P2 = only the scope/secret literals inside, if any).
- docs/ — 718 doc hits: STAYS as history, except docs/compliance/C6_OAUTH_OIDC.md,
  C1_ARM_REST.md and the KD/register files that restate the credential contract —
  those re-state the neutral model + azurerm dialect mapping in phase 2.
- test/ (smalt) — tests pinning the Azure shape of the face: STAYS as
  dialect-1 compat tests; new neutral-core tests are ADDED, not mutated.

Existing tests pinning Azure shape stay as dialect-1 compat tests.

### 3.2 courtroom-platform-az repo (@ 31c58e9 working tree)

| file | hits | class |
|---|---|---|
| .github/workflows/infra-dev.yml:26,38-40,93-95 | ARM_USE_OIDC, ARM_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID from `vars.AZURE_*` | **P2** — real-Azure CI leg; maps via azurerm dialect mapper against real Azure (or smalt substrate), core env contract `SMALT_TENANT_ID` first, `ARM_*` as dialect aliases |
| apps/web/test/harness/lib/smalt-client.ts:12-19 | POST /smalt/oauth2 coords, zero-guid client_id, secret literal, management.azure.com/.default | **P2** |
| apps/web/test/harness/vault/lib.ts:44-52 | same shape, data-plane (KV) scope rendering | **P2** |
| apps/web/test/harness/nfr/hermetic.test.ts:24,43,128 | management.azure.com as *egress-canary* URL, not a credential | **STAYS** (egress canary, not a credential; hermetic-guard may keep citing the Azure URL as the "outside" it must not reach) |
| scripts/hermetic_guard.sh:5,11, Azure scope as string-match marker | egress-guard using the Azure scope string as a canary marker | **STAYS** (guard uses the string as an egress canary, not a credential) — note: guard's allowlist pattern must keep the scope literal until dialect extraction, then guard updated to allow the mapper module |
| apps/web/test/harness/nfr/cleanup.test.ts:18 | zero-guid SUB as mock id | P2 (trivial, part of harness factory) |
| docs/jira/.../HRN-014-runner-config.md:27-38, receipts/hrn-009-hermetic.md | restate the STS bearer recipe | P2 (docs restate neutral model, keep azurerm recipe as dialect-1 recipe) |
| docs/jira/.../HRN-009-nfr-hermetic.md | SMALT_ARM_ENDPOINT contract | P2 (docs) |
| receipts/gaps/h6-hrn-006-tc-ver.md | history receipt | STAYS |
| scripts/harness_court.sh:73-78 | env contract is SMALT_ARM_ENDPOINT, no Azure string | **STAYS** (already neutral) |

### 3.3 Counts re-read from grep output this session

- smalt: 718 doc hits-files, ~260 non-docs hit-files
- platform-az: 12 files, classified in §3.2

## 4. Phased close conditions

**Phase 1 (this migration): spec only.** Close: this file exists, census
complete, every hit classified, neutral core model spec delivered
(docs/jira/v26.10.31/gaps/09-credential-core-model.md), zero code changed.
DONE (2026-10-30, lane M9).

Phase 1 close (this lane): this file + census. Close when: this file lands;
zero code changed by lane 9.

**Phase 2 (dialect extraction)**: introduce `Smalt.Cred.Core` +
`Smalt.Cred.Dialect` behaviour; every consumer file marked P2 above re-points
to the factory; azurerm mapper reproduces the byte-identical dialect-1 wire
(a court asserts byte-identical STS response for a recorded request corpus);
a new-dialect court proves a second dialect mints/verifies without touching
oidc_sts.ex.

Phase 2 close: (a) `Smalt.Cred.Core`/`Smalt.Cred.Dialect` land in smalt lib;
(b) every P2 consumer re-pointed (list = §3 P2 rows), zero hardcoded
scope/secret/zero-guid literals outside the azurerm dialect module + STS face
+ hermetic canary; (c) dialect-1 byte-identical court passes; (d) a second-dialect court passes (a non-Azure dialect mints + verifies with zero oidc_sts.ex change); (e) hermetic guard still PASSes (allowlist updated with disclosed allowlist diff).

**Phase 3 (face inversion, out of scope here)**: smalt STS face speaks the
neutral wire; azurerm compat face remains only behind a flag; all env
contracts read SMALT_* first with ARM_* as dialect aliases; docs/compliance
(C1, C6) rewritten neutral-first.

---

### Appendix: raw census trees (re-read this session)

Smalt non-docs hit tree (verbatim from grep -l output this session) is
preserved in the session tool-results cache at
/Users/sac/.claude/projects/-Users-sac-cai-courtroom-platform-az/1c574a6c-b09c-4760-a527-2e6ee1555204/tool-results/b3twfys61.txt
(58.1KB, 718 docs files + ~260 non-docs files, one path per line).
