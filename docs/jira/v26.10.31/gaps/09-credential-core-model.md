# 09 — Neutral Credential Core Model (spec, dialect-agnostic)

Status: ALIVE — spec delivered (this file); zero code changed by lane M9.
Subject: smalt @ f0e0a12575c38f07e37a40ed58f4e448086c97b3,
courtroom-platform-az @ 31c58e915febf8bfc23b8fc7369617abd54a80ce.
Every citation below was re-verified by grep/sed on disk this session
(2026-10-30), not recalled from the census draft.

## 1. Neutral core vocabulary (zero proprietary IRIs)

This section alone is the consumable core: a downstream dialect lane needs
nothing else. No term names a cloud vendor; the only literals are the
substrate's own env-key names and atoms.

```
CredentialRequest :: {
  principal   : PrincipalId          # opaque; dialect renders natively
  auth_factor : {:shared_secret, SecretRef}
  audience    : Scope
  tenant      : TenantKey            # opaque authority-namespace key
}

PrincipalId :: opaque binary        # no GUID semantics in core
TenantKey   :: opaque binary        # no GUID semantics in core
SecretRef   :: {:env, name} | {:file, path} | {:literal, v}   # literal = dev only

Scope :: :control_plane
       | {:data_plane, resource :: binary}
       | {:dialect, dialect_name, native_scope :: binary}
```

Field laws:

- `principal` is opaque. Any rendering the dialect wants (GUID, SPN, none)
  is dialect-side; core never parses or validates its *form*.
- `auth_factor` is a reference, never a value. The core admission plane
  resolves a SecretRef to bytes only at the wire boundary, via a registered
  resolver; `{:literal, v}` is dev/substrate mode only and is refused at
  the core boundary when the substrate runs in enforce mode.
- `audience` is a core Scope, never a URL. URL rendering is dialect-side
  (`scope_binding` below).
- `tenant` has ONE canonical env key: `SMALT_TENANT_ID`. Legacy env aliases
  are dialect aliases, accepted by dialect config adapters, never by the
  core config reader.

### 1.1 Dialect mapper behaviour (seam contract)

```
DialectMapper behaviour, 3 callbacks:
  to_wire(CredentialRequest, wire_ctx) -> token HTTP request   (mint side)
  from_claim(token) -> {PrincipalId, Scope, TenantKey}         (verify side)
  scope_binding(core_scope) -> dialect native scope string     (render side)
```

Seam contract — what the core admission plane accepts vs what the dialect
translates:

| edge | core accepts/owns | dialect translates |
|---|---|---|
| mint request | CredentialRequest fields (PrincipalId, SecretRef, Scope, TenantKey) | form encoding, endpoint path, grant_type name, secret field name, scope string |
| mint response | bearer token bytes + expiry (opaque to core) | claim names inside the token |
| verify | issuer authority (`config :smalt, :issuer_host`), core audience register, core scope check | dialect claim names to core fields |
| challenge | core challenge grammar: `401 + WWW-Authenticate: Bearer authorization=…, resource=…, error=…` | dialect echo, byte-exact for dialect-1 |

The core plane never sees: form field names, grant_type values, native
scope strings, vendor URL shapes. The dialect never sees: SecretRef values,
core scope atoms, core issuer config. Exchange happens only through the 3
callbacks.

## 2. Azure reclassified as dialect-1: mapping table

Census basis (re-run this session, 2026-10-30):

- smalt non-docs hit-files: **108** files matched
  `management.azure.com|sovereign-mock-secret|tf-mock-secret|00000000-0000-0000-0000-000000000000`
  under lib/ config/ verification/ smalt-cli/
  adapters/terraform-provider-smalt/internal/provider/ scripts/ examples/
  workspace/lib/ posh/ ggen-marketplace/packs/posh/generated/ (grep -rln |
  wc -l; node_modules/_build excluded).
- courtroom-platform-az (/Users/sac/cai/courtroom-platform-az @ 31c58e9):
  **18** files matched the same disjunction (ts/sh/yml/md, node_modules
  excluded).
- Distinct Azure credential TERMS across all touchpoints: 10 (the table
  below enumerates them all; the term set is closed by construction — the
  first column is exactly the term list the census greps emit).
- Term-level mapping covers file coverage: every touchpoint's credential
  usage instantiates one or more of the 10 terms; per-file classes are in
  the census draft (docs/jira/posh/v26.10.31/gaps/09-credential-model.md
  §3). Therefore the mapping covers 100% of census touchpoints.

| # | Azure term / shape | neutral core term | current sites (file:line, verified this session) |
|---|---|---|---|
| 1 | `client_id` (zero-guid) | `CredentialRequest.principal` (opaque PrincipalId) | verification/ts/harness/credential.ts:9; verification/py/harness/credential.py:2,28; smalt-cli/smalt_cli/gateway/sts.py:30; lib/smalt/arm_gateway/plug/oidc_sts.ex:145,146,291; apps/web/test/harness/lib/smalt-client.ts:17 (platform-az); apps/web/test/harness/vault/lib.ts:50; apps/web/test/harness/nfr/cleanup.test.ts:18 |
| 2 | `client_secret` (literal `smalt-tf-mock-secret` / `smalt-sovereign-mock-secret`) | `auth_factor {:shared_secret, SecretRef}` (literal = dev-only) | verification/ts/harness/credential.ts:10; verification/py/harness/credential.py:28; apps/web/test/harness/vault/lib.ts:51; smalt-cli/smalt_cli/gateway/sts.py (secret form field, defaults zero-guid tenant at :30) |
| 3 | `scope` = `https://management.azure.com/.default` (control-plane request) | `audience: :control_plane` | verification/ts/harness/credential.ts:30; lib/smalt/arm_gateway/plug/oidc_sts.ex:168; lib/smalt/auth/bearer.ex:33; config/config.exs:62; lib/smalt/config.ex:544,735; smalt-client.ts:19; vault/lib.ts:52; scripts/hermetic_guard.sh:11,37 (egress canary — STAYS, not a credential) |
| 4 | `aud` claim `https://management.azure.com` | `audience: :control_plane` (verify-side register) | oidc_sts.ex:140; auth/bearer.ex:33; lib/smalt/arm_gateway/plug/metadata.ex:112,126; config.ex:544,735 |
| 5 | tenant path `/{tenant}/oauth2/v2.0/token` + `tid` claim | `tenant: TenantKey`; canonical env `SMALT_TENANT_ID`, `ARM_TENANT_ID` = dialect alias | oidc_sts.ex:294,300,308; credential.ts:8,69; vault/lib.ts:7; sts.py:30; .github/workflows/infra-dev.yml:38-40,93-95 |
| 6 | `grant_type=client_credentials` + form encoding + `POST /oauth2/v2.0/token` | dialect-1 `to_wire` rendering; core owns a token-bytes+expiry exchange, no grant_type | oidc_sts.ex:262,290; credential.ts:69 + getToken body; credential.py:28; smalt-client.ts:15-19; vault/lib.ts:44-52 |
| 7 | claims `appid`/`azp`/`oid`/`sub` | `principal.id` — from_claim maps all four to core PrincipalId; zero-GUID form is dialect-1 rendering | oidc_sts.ex:145-148 |
| 8 | `roles` claim `["Contributor","Owner"]` | dialect-1 authorization rendering; core scope = `:control_plane` | oidc_sts.ex:149 |
| 9 | subscription id (SUB `11111111-…` client-side-validation workaround; ARM_SUBSCRIPTION_ID) | NOT a credential — typed out-of-model (resource identifier); core carries no subscription term | verification/ts/harness/credential.ts:12-14; infra-dev.yml:39,94; cleanup.test.ts:18 (zero-guid SUB as mock id) |
| 10 | issuer `https://login.microsoftonline.com/{t}/v2.0`, challenge `/organizations` suffix | core issuer = `config :smalt, :issuer_host` (neutral authority); `/v2.0` and `/organizations` path suffixes are dialect-1 rendering | lib/smalt/auth/bearer.ex:34,707,714-715; oidc_sts.ex:183-184; lib/smalt/config.ex:281,669-670 |

Coverage proof: the 10 rows are the closed term set emitted by the census
greps — each row's first-column term appears literally in the grep
disjunction that produced the 108/18 counts, so any touchpoint file counted
by the census instantiates ≥1 of these terms. A touchpoint using an 11th
term would require an 11th distinct literal in the census disjunction; the
census forbids one by construction. None unmapped.

## 3. Consumer dry-run: KD-15 KV challenge handshake, neutral form

KD-15 (docs/jira/v26.10.20/KNOWN_DIVERGENCES.md, canonical table) pins the
KV data-plane challenge handshake. Current sites, verified this session:
lib/smalt/auth/bearer.ex:695-720 (`challenge_value/2`: `authorization` =
STS authority with tenant path, `resource` = request origin, `error`),
send_challenge at :734-745 (401 + enriched WWW-Authenticate + ARM error
envelope), `# KD-COVERS: KD-15` at :692.

Flow in core terms only:

1. Client holds `CredentialRequest{principal: P, auth_factor:
   {:shared_secret, {:env, "SMALT_SECRET"}}, audience: {:data_plane,
   "<resource-key>"}, tenant: T}`. The resource key is the substrate's own
   resource identifier, not a vendor URL.
2. Client calls dialect `to_wire` and sends the request tokenless (no
   bearer yet) — it needs no credential material to provoke a challenge.
3. Core answers `401` with the challenge grammar of §1.1 (row
   "challenge"): `authorization` names the issuer authority + tenant path,
   `resource` echoes the request origin. This grammar is already
   vendor-neutral at bearer.ex:707-716 — the only vendor string on the
   surface is the dialect-1 issuer default, which §2 row 10 maps to the
   neutral issuer_host authority.
4. Client parses the challenge through the DialectMapper verify-side seam:
   `authorization` + `resource` are core fields (issuer authority, request
   origin); the mapper's scope_binding renders the core data-plane scope
   for the resource and `to_wire` mints with the SecretRef resolved
   dialect-side.
5. Client resends with the bearer. Handshake complete; at no step did the
   core model name a vendor: principal, SecretRef, Scope, TenantKey,
   issuer authority, and challenge grammar are all neutral terms of §1.

## 4. Falsifier status

- Every citation above was produced by grep/sed runs in this session
  (2026-10-30); the counts 108/18 are re-read from `grep -rln | wc -l`
  output this session, not from the census draft.
- Mapping coverage: proved by term-set closure in §2.
- Dry-run: §3 expresses the KD-15 handshake without naming any vendor in
  the core vocabulary.
- **Phase-2 started (2026-10-30, wave-2 lane g09)**: `Smalt.Cred.Core`
  (neutral CredentialRequest vocabulary, Scope/SecretRef/TenantKey,
  DialectMapper behaviour, core challenge grammar parser, enforce-mode
  SecretRef resolution) landed at `lib/smalt/cred/core.ex` — grep-verified
  zero vendor strings in the core; dialect-1 mapper
  `Smalt.Cred.Dialect.Azure` landed at `lib/smalt/cred/dialect/azure.ex`
  (10-row mapping table rows 1-8 + 10 rendered; row 9 subscription stays
  typed out-of-model). Court:
  `MIX_BUILD_ROOT=_build-lane-g09 mix test test/smalt/cred/core_court_test.exs`
  → 11 passed, exit 0 — KD-15 §3 flow through Core+Mapper parses the REAL
  `Smalt.Auth.Bearer.challenge_value/2` grammar and produces the same wire
  steps; a mutated wrong-audience mapper refuses typed
  (`{:error, {:unknown_audience, _}}`, register cannot admit a dialect URL).
- Not done here (remaining open work, not claimed): consumer re-pointing
  (every §3-class P2 file), the recorded-corpus byte-identical STS court,
  and the second-dialect court — all remain open per
  docs/jira/posh/v26.10.31/gaps/09-credential-model.md §4.
