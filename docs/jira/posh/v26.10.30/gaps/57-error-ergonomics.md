# GAP-57: Typed-failure ergonomics audit

Lane 4, 2026-10-30. Scope: every typed failure string in this estate.
ALIVE claim: table below was compiled from real grep/reads of the working tree
this session; the 3 disclosed message edits are on disk in the two workflow files.

## Estate scope note (honest)

The dispatch named tag families that do NOT exist in this repo
(`justfile.d/`, `posh/internal`, `adapters/`; `[POSH-*]`, `[TF-*]`, `[SLA-*]`,
`[KIND-*]`, `[INVARIANT-*]`, `[BOOTSTRAP-*]`, `[DOCTOR-*]`, `[TF-ARCHIVED]`,
CROSSCHECK/MISMATCH, VACUOUS, InvalidApiVersionParameter, AdmissionRefused,
GraphLaw not-admitted). Zero grep hits for all of them. Those rows are absent
not silently skipped: the families are NOT-PRESENT in this estate. The estate's
actual typed surface is 4 families:

1. `GUARD-*` bracket tags (scripts/guard_local_apply.sh + its court)
2. GitHub Actions `::error` annotations (2 workflows)
3. API error codes (TS: SAML codes, authorization denials, session errors)
4. Terraform `error_message` validations + config.ts startup throws

## Failures runbook

| # | Message (emitted verbatim) | Where emitted | Cause | Fix named in-message? | Doc pointer | Status |
|---|---|---|---|---|---|---|
| 1 | `[GUARD-LOCAL-APPLY-USAGE] usage: guard_local_apply.sh <tf-root-dir> <terraform-args...>` | scripts/guard_local_apply.sh:37 | wrong arg count | yes (usage line IS the fix) | header comment, README fence section | PASS |
| 2 | `[GUARD-LOCAL-APPLY-FAIL] root dir not found: $ROOT` | scripts/guard_local_apply.sh:44 | root path arg wrong/typo | no (names cause, not fix) | none in-message | GAP (close: append `pass the tf root dir, e.g. infra/environments/dev/platform`) |
| 3 | `[GUARD-LOCAL-APPLY] PASS (non-mutating command '...')` | guard_local_apply.sh:53 | n/a (pass) | n/a | — | PASS |
| 4 | `[GUARD-LOCAL-APPLY] PASS (SMALT_LOCAL=1 escape hatch...)` | guard_local_apply.sh:60 | n/a (pass) | n/a | in-message | PASS |
| 5 | `[GUARD-LOCAL-APPLY] PASS (no backend block in $ROOT...)` | guard_local_apply.sh:66 | n/a (pass) | n/a | — | PASS |
| 6 | `[GUARD-LOCAL-APPLY] PASS (backend initialized in $ROOT...)` | guard_local_apply.sh:97 | n/a (pass) | n/a | — | PASS |
| 7 | `[GUARD-LOCAL-APPLY-REFUSE] terraform $CMD refused in $ROOT` + heredoc | guard_local_apply.sh:87-93 | backend-declared root, backend-stripped apply/destroy | yes (Remedy: terraform init / SMALT_LOCAL=1) | in-message: `scripts/guard_local_apply.sh`; README:150 "Local apply fence (GAP6(b))" | PASS (model row) |
| 8 | `[GUARD-TEST-FAIL] $label: expected exit $want, got $got` | scripts/guard_local_apply_test.sh:35 | court case diverged | partial (names got/want; dump follows) | court header | PASS |
| 9 | `[GUARD-TEST] FAIL: $fails case(s) failed` | guard_local_apply_test.sh:58 | ≥1 case failed | partial | — | PASS (court-internal) |
| 10 | `::error::backend block removed from a tf root — ...` | .github/workflows/infra-dev.yml:66 | GAP6(b) backend-strip diff detected | WAS no → **FIXED this session**: now names restore-backend / SMALT_LOCAL=1 / README section | now in-message | CLOSED (disclosed edit) |
| 11 | `::error::$app: revision $latest did not become ready` | .github/workflows/deploy-dev.yml:70 | revision never reached ready in 40x15s | WAS no → **FIXED**: now gives `az containerapp revision list` + logs commands | now in-message | CLOSED (disclosed edit) |
| 12 | `::error::$tenant: health check failed` | deploy-dev.yml:93 | /api/health or /api/sso/status failing on tenant fqdn, 20x5s | WAS no → **FIXED**: now names URL + `az containerapp logs show` command | now in-message | CLOSED (disclosed edit) |
| 13 | `no certificate found` (throw) | apps/api/src/certificates.ts:30 | SAML cert config empty | no | none | GAP (close: message → `no SAML idp certificate configured — set SAML_IDP_CERTIFICATE (see config.ts)`) |
| 14 | config.ts throws: "must be an origin without path...", "must not contain credentials or a fragment", "must be a tenant GUID", "must be an https URL or urn: identifier" | apps/api/src/config.ts:79-97 | invalid env var value at startup | yes (each names the requirement = the fix) | none (env var name is in the caller context) | PASS (borderline: no README env-var table to link; see gaps) |
| 15 | `{ error: "sso_not_configured" }` (503) | apps/api/src/auth.ts:80,174 | SSO env not set | no (bare code) | none | GAP-minor (operator-facing; close: log line naming the missing env vars) |
| 16 | `{ error: "authentication_required" }` (401) / `session_expired` | auth.ts:87,91 | no/expired session | n/a (client-protocol codes; frontend handles) | frontend session.ts consumes | PASS |
| 17 | `{ error: denial }` — codes: `tenant_mismatch`, `authorization_not_configured`, `groups_overage`, `access_denied` (403) | auth.ts:98 + claims.ts:44 | Entra authorization denial | no in-message; paired `logger.warn` carries reason | none | GAP-minor (codes are typed+machine-readable; a docs table mapping code→operator fix is the close condition) |
| 18 | `{ error: "session_error" }` + `logger.error session_create_failed / session_save_failed` | auth.ts:155,163 | session store write failed | server-side reason in log, client gets bare code | — | PASS (split-channel by design) |
| 19 | `{ error: "cross_origin_request_rejected" }` (403) | auth.ts:207 | CSRF origin mismatch | no | none | GAP-minor (close: log the offending Origin header alongside) |
| 20 | SAML codes: `saml_invalid` / `saml_expired` / `saml_replayed` / `idp_error` / `login_state_missing` | apps/api/src/saml.ts:17, auth.ts:140-148 | typed SamlRejection | `logger.warn saml_rejected` carries code+reason server-side | none | PASS server-side; no public doc of codes |
| 21 | TF `error_message = "Required tenant secret missing from the dev Key Vault."` | infra/environments/dev/platform/secrets.tf:79 | missing Key Vault secret | names the requirement | none | GAP-minor (close: name the secret key(s)) |
| 22 | TF `error_message = "The slug must be 2-16 lowercase letters or digits and start with a letter."` | infra/modules/tenant-apps/variables.tf:7 | invalid tenant slug | yes (regex-as-prose IS the fix) | — | PASS |
| 23 | console.error `session_lookup_failed` / `backend_proxy_failed` / `unhandled_error` | apps/web/src/lib/session.ts:96, backend.ts:59, apps/api/src/app.ts:59 | runtime errors, structured log events | reason in payload | — | PASS (log events, not user-facing failures) |

## Gap count and worst offenders

Honest gap count: **9 gaps** (rows 2, 10-12 pre-fix, 13, 15, 17, 19, 21).
3 of the 9 closed this session by disclosed message edits (10, 11, 12).
Remaining open: **6** (rows 2, 13, 15, 17, 19, 21). 23 rows inventoried.

Top offenders by (operator-likelihood x missing-remediation):

1. Row 11/12 (deploy-dev `::error`s) — most likely real on-call page — CLOSED
2. Row 10 (backend-strip gate) — blocks PRs with no fix named — CLOSED
3. Row 13 `no certificate found` — startup crash, cryptic, no env var named — OPEN
4. Row 2 guard FAIL line — first contact for a mistyped guard invocation — OPEN
5. Row 17 authorization denial codes — no code→fix documentation anywhere — OPEN
6. Row 21 secrets.tf error_message — doesn't name which secret — OPEN
7. Row 15 sso_not_configured 503 — no server-side hint of missing vars — OPEN
8. Row 19 cross_origin_request_rejected — no offending-origin log — OPEN
9. No doc anywhere mapping API error codes → remediation (family-level gap covering rows 15/17/19/20) — OPEN

Close conditions: all open rows are one-line message edits or one README table
(`## Error codes` mapping codes 15/17/19/20 → cause+fix); nothing needs new
machinery.

## Other receipts

- 3 disclosed message edits (rows 10, 11, 12) — trivial, unambiguous,
  message-string-only, no logic touched.
- Stray `erl_crash.dump` at repo root (untracked artifact, not failure-string
  related) — flagged for cleanup lane.
- Non-vacuity: table rows cite file:line read this session; row 7's REFUSE
  message is the estate's model row (cause+remedy+doc in-message).
