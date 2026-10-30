# GAP-21: Environment variable matrix and cross-runtime precedence hazards

Status: **PARTIAL** — full matrix built for every env var actually read in this repo
(command `grep -n 'env\[\|env\.' apps/api/src/config.ts apps/web/src/**/*.ts` +
`.env.example` diff + workflow/guard sweep, receipts below). The lane brief names three
runtimes (smalt BEAM, Go provider, posh); none of their code exists in this repo
(`lib/smalt/config.ex`, any `*.go`, any POSH_* read: zero matches). Matrix below covers
the repo's real surface; close condition extended to reconcile the brief's assumed
runtimes with this repo.

## 1. Unified env matrix (subject: HEAD 31c58e9, main)

Legend: read = file:line of the read site; default = value when unset/empty.
`loadConfig` treats `""` as unset (`if (!env[name])`, apps/api/src/config.ts:131).

### Node API (apps/api/src/config.ts, `loadConfig`)

| Var | Read at | Default | Documented in |
|---|---|---|---|
| APP_ORIGIN | config.ts:143 | none — REQUIRED, SSO stays disabled without it | .env.example; README:54 |
| FRONTEND_URL | config.ts:144 | APP_ORIGIN | .env.example |
| ENTRA_TENANT_ID | config.ts:145 | none — optional, gates SAML_ENTRY_POINT/SAML_IDP_ISSUER derivation | .env.example |
| SAML_ENTRY_POINT | config.ts:147-151 | `https://login.microsoftonline.com/${ENTRA_TENANT_ID}/saml2` | **UNDOCUMENTED** |
| SAML_IDP_ISSUER | config.ts:152-156 | `https://sts.windows.net/${ENTRA_TENANT_ID}/` | **UNDOCUMENTED** |
| SAML_ISSUER | config.ts:157 | APP_ORIGIN | .env.example |
| SAML_CALLBACK_URL | config.ts:158-160 | `${APP_ORIGIN}/saml/acs` | **UNDOCUMENTED** |
| SAML_IDP_CERT / SAML_IDP_CERT_PATH | config.ts:166-169 | none — one required for SSO | .env.example |
| COOKIE_SECURE | config.ts:185-188 | `https:` APP_ORIGIN ? true : production; forced true+required in production (config.ts:189) | **UNDOCUMENTED** |
| AUTH_ALLOWED_GROUP_IDS / _ROLES | config.ts:194-195 | empty | .env.example |
| AUTH_ALLOW_ALL_ASSIGNED_USERS | config.ts:196-197 | false | .env.example |
| AUTH_GROUP_LABELS | config.ts:266 | empty | .env.example |
| PORT | config.ts:204 | 8080 (clamped 1-65535) | .env.example |
| SESSION_SECRET | config.ts:179-183 | none — required; each ≥32 chars | .env.example |
| SESSION_MAX_AGE_MS | config.ts:205-208 | 8h, clamp 5min-24h | .env.example |
| SAML_WANT_RESPONSE_SIGNED | config.ts:209-210 | false | **UNDOCUMENTED** |
| SAML_CLOCK_SKEW_MS | config.ts:211-213 | 2min, clamp 0-10min | **UNDOCUMENTED** |
| SAML_REQUEST_TTL_MS | config.ts:214-216 | 10min, clamp 1min-1h | **UNDOCUMENTED** |
| SAML_MAX_ASSERTION_AGE_MS | config.ts:217-220 | 10min, clamp 1min-1h | **UNDOCUMENTED** |
| SAML_NAMEID_FORMAT | config.ts:245 | `urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified` | **UNDOCUMENTED** |
| SAML_IDP_LOGOUT_URL | config.ts:221 | undefined (app-local sign-out only) | .env.example |
| REDIS_URL | config.ts:223 | undefined; production warning without it | .env.example |
| TRUST_PROXY | config.ts:255 | `loopback, linklocal, uniquelocal, 100.64.0.0/10` (config.ts:10) | .env.example |
| NODE_ENV | config.ts:142 | undefined → production=false | **UNDOCUMENTED** (conventional) |

### Web (apps/web/src)

| Var | Read at | Default | Documented |
|---|---|---|---|
| CANONICAL_ORIGIN / REDIRECT_HOSTS | apps/web/src/lib/canonical-host.ts:17-19 | none — no redirect behavior | .env.example, README:72 |
| TENANT_DISPLAY_NAME | apps/web/src/lib/tenant.ts:7 | undefined | .env.example |
| BACKEND_URL | apps/web/src/lib/backend.ts:8 | undefined (auth routes proxy fails) | .env.example |
| PORT (web) | via Next `next start` only | 3000 | .env.example |

### Terraform / CI (.github/workflows/infra-dev.yml)

| Var | Read by | Where set | Documented |
|---|---|---|---|
| ARM_CLIENT_ID / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID | azurerm provider OIDC auth | workflow:38-40 (plan), 93-95 (apply), from `vars.AZURE_*` | README:95-97 (as AZURE_*), README:146 |
| ARM_USE_OIDC | azurerm provider | workflow:26, hardcoded `"true"` | **UNDOCUMENTED** |
| TF_IN_AUTOMATION / TF_INPUT | terraform CLI | workflow:24-25, hardcoded | **UNDOCUMENTED** |
| TF_VAR_subscription_id / TF_VAR_entra_tenant_ids | terraform variables | workflow:41-42, 96-97 | README:146 (as ENTRA_TENANT_IDS JSON) |
| SMALT_LOCAL | scripts/guard_local_apply.sh:59 | operator shell | README:150 (escape hatch) |
| TF_CLI_CONFIG_FILE | terraform CLI (smalt emulator rc) | not set anywhere in-repo — README:148 says "generated rc" but no generator exists here | README:148 only, **no in-repo writer** |
| AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID | GitHub environment vars feeding ARM_* | GitHub environments | README:94-97, 146 |

## 2. Collision / hazard rows

- **H1 (name collision, cross-runtime)**: `AZURE_TENANT_ID` — two meanings. (a) README:95:
  the *subscription's* Entra tenant (deployment identity, feeds ARM_TENANT_ID). (b)
  config.ts:145 `ENTRA_TENANT_ID`: the *IdP* tenant for sign-in. Distinct names, but the
  README table presents AZURE_TENANT_ID generically; a shell exporting AZURE_TENANT_ID for
  az CLI does NOT configure SSO (the API wants ENTRA_TENANT_ID). Near-collision, documented
  divergence only by convention. Also `TF_VAR_entra_tenant_ids` (plural map) vs
  `ENTRA_TENANT_ID` (singular GUID) in the same workflow — three tenant-ID spellings.
  Close: single env doc renaming/annotating each by consumer.
  Close condition: one canonical env doc (this file promoted or a generated
  ENVIRONMENT.md) + a court asserting code-read vars == doc'd vars (fail on undocumented
  read or doc'd-but-unread), plus default assertions mirroring config.test.ts.
- **H2 (precedence, same shell)**: `PORT` is read by BOTH apps with different defaults
  (API 8080 config.ts:204, web 3000 .env.example). Exporting a shared `PORT` in one shell
  silently re-points one of them; container wiring must set it per-app, not per-shell.
- **H3 (dangling doc)**: README:148 references a smalt-emulator rc via TF_CLI_CONFIG_FILE
  as "the generated rc" — no generator script exists in this repo. Documentation references
  an out-of-repo runtime; if the smalt toolchain exports TF_CLI_CONFIG_FILE plus
  SMALT_ARM_* aliases into the operator shell (per lane brief), nothing here pins which
  values win when both runtimes run in one shell. Evidence gap, not fixable in-repo.
- **H4 (undocumented knobs, 9 vars)**: SAML_ENTRY_POINT, SAML_IDP_ISSUER,
  SAML_CALLBACK_URL, COOKIE_SECURE, SAML_WANT_RESPONSE_SIGNED, SAML_CLOCK_SKEW_MS,
  SAML_REQUEST_TTL_MS, SAML_MAX_ASSERTION_AGE_MS, SAML_NAMEID_FORMAT, NODE_ENV — all read and defaulted in config.ts with clamps
  (e.g. SESSION_MAX_AGE_MS clamp 5min-24h) that are load-bearing and reachable only by
  reading config.ts.
- **H5**: ARM_USE_OIDC hardcoded true + AZURE_*→ARM_* indirection means a local shell with
  AZURE_* exported does NOT authenticate terraform (OIDC only) — `az login` + no ARM_* is
  fine (default Azure CLI chain), but ARM_USE_OIDC=true leaking into a local env (e.g.
  from an exported CI env dump) would break local auth silently.
- **H6**: guard escape hatch SMALT_LOCAL=1 is name-spaced like the external smalt runtime
  (SMALT_*) but is a local guard flag; if a future smalt toolchain defines SMALT_LOCAL for
  a different purpose, the guard's PASS flips — name-space squatting hazard on the SMALT_
  prefix this repo does not own.

## 3. Verification receipts (commands + exits)

- `grep -n 'env\[\|env\.' apps/api/src/config.ts apps/web/src/lib/*.ts apps/web/src/proxy.ts`
  → full read-site list above (exit 0).
- `grep -rn "process\.env" ...` → 4 files, all delegating to loadConfig/readCanonicalHostConfig.
- Undocumented check: loop of `grep -qr "$v" README.md apps/*/.env.example` over all 19
  doc-surface vars → 0 UNDOCUMENTED lines among them (exit 1 on last grep, expected);
  the 10 undocumented reads found only in config.ts quoted-string sweep.
- No Go/BEAM/POSH code: `grep -rn 'os.Getenv' .` → no matches;
  `ls lib/smalt` → absent (this is courtroom-platform-az, not smalt).

## 4. Close condition

1. Promote §1 into a single generated env doc (source: config.ts + .env.example + workflow,
   checked in, not hand-written).
2. Add a court (extend scripts/guard_local_apply_test.sh pattern): a doc-coverage gate that
   greps every quoted env name in config.ts against README + .env.example; exit 1 on any
   read-but-undocumented var (H4); flip H1/H2 rows to CLOSED when the doc carries
   per-consumer annotations.
3. Resolve brief/repo mismatch: the smalt BEAM alias table, Go provider ARM_*/TFPOSH_*
   reads and posh POSH_* reads live in the smalt/posh repos, not here — re-scope lane 21's
   cross-runtime rows to that fleet or delete the rows here.
