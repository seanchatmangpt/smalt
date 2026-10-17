# Archive

Point-in-time evidence and audit documents from closed windows, preserved for
replay/history via git. None of these are living documentation; the live
surface is the parent `docs/` tree plus the mechanical gates in `justfile.d/`.

| Archived file | Why archived | Superseded by |
|---|---|---|
| `CHEAT_SCAN.md` | One-shot anti-LLM-cheat scan log (2026-10-14 re-scan); evidence snapshot, not a gate | `scripts/naming_sweep.sh` gate (`just naming-sweep`) + `docs/ERROR_SWEEP.md` |
| `CLEANUP_FINAL.md` | 2026-10-14 integration cleanup receipt (lane build-root sweep); closed action | Cleanup law is permanent rule text in CLAUDE.md / `just lane-clean` |
| `DEP_AUDIT.md` | Dependency advisory audit as-of 2026-10-14; advisory surface is stale by construction | Fresh `mix deps.audit`/`MIX_ENV=prod mix deps.get` run per window |
| `NAMING_SWEEP.md` | Point-in-time naming/leak audit ledger (2026-10-14/15 passes) | Mechanized fail-closed gate `scripts/naming_sweep.sh` (same grep, allowlist-keyed) |
| `PUBLISH_CHECK.md` | v26.10.14 publish-readiness court (v1–v4 verdicts, 2026-10-14/15); window-closed snapshot | `just publish-dry` (`scripts/publish_dry.sh`) per window |
| `QUICKSTART_RECEIPT.md` | Lane-19 quickstart verification receipt (2026-10-14); superseded receipt | `docs/FIRST_RUN.md` + `bash scripts/bootstrap.sh` (idempotent, re-runnable) |
| `RELEASE_NOTES_v26.10.14.md` | Release notes for the closed v26.10.14 window | `docs/RELEASE_NOTES_v26.10.16.md` (current); v26.10.14 history also in `CHANGELOG.md` and `docs/jira/v26.10.14/` |
| `auth_regression_sweep.md` | 2026-10-15 post-IssuerMismatch-fix verification sweep receipt; one-time evidence | `docs/ERROR_SWEEP.md` ledger + the test suites it cites |

Not archived (checked, still load-bearing): `DEV_ENV.md`, `FIRST_RUN.md`,
`ERROR_CODES_GENERATOR.md`, `SEMANTIC_PROJECTION.md`,
`MIGRATION_FROM_EMULATORS.md` (no successor explanation/reference file exists),
`TERRAFORM_TRUST.md` (sole TLS-trust-model doc), `XAAS_PRIOR_ART.md` (active
transfer plan, G1 witness referenced by the current window's DEV_LOOP).

Known stale path mentions left in place on purpose: dated journal lines in
`docs/how-to/dev-loop.md` (historical log, rewriting would falsify the record) and
references inside `docs/jira/**` (permanent milestone receipts, excluded from
this lane by charter). `docs/archive/NAMING_SWEEP.md:32` self-references the
old QUICKSTART_RECEIPT path for the same reason.
