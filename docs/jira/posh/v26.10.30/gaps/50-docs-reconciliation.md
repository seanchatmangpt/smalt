# 50 Docs Reconciliation (lane 50, docs-only)

Status: ALIVE — all four reconciled, 2026-10-30.

Subjects:
- consumer: `/Users/sac/cai/courtroom-platform-az` (HEAD 31c58e9)
- substrate: `/Users/sac/smalt` (working tree)

## Edits

1. `/Users/sac/cai/courtroom-platform-az/README.md` (Local-development
   limitations table):
   - `azurerm_role_definition` row: UNSUPPORTED → LIVE on the smalt plane
     (2026-10-30, lane C1). Evidence re-read on disk:
     `adapters/terraform-provider-smalt/internal/provider/resource_remaining_v1.go:864`
     (`roleDefAPIVersion = "2022-04-01"`), computed
     `role_definition_resource_id` set at :1266 and roundtripping into
     role_assignment (`roleAssignAPIVersion = "2022-04-01"` :1280);
     live_test.go:138 documents the 2022-04-01 live run.
   - UAI row re-checked against C2: data source is no longer the silent
     half — `data_sources_v1.go:469-476` now routes both client_id and
     principal_id through `carryOrMintIdentityAttr` with diags
     (error-by-default). Row rewritten: both halves loud; residual is
     plane-level (no real Entra ids on smalt plane). Receipt:
     `adapters/terraform-provider-smalt/scripts/receipts/c2-honesty-law-2026-10-30.md`.
2. `/Users/sac/smalt/docs/jira/posh/v26.10.30/dfcharter/design.md`:
   - Tree line (~:273): `terraform-provider-smalt/` →
     `adapters/terraform-provider-smalt/` with a dated note that the
     top-level Elixir spike was archived to
     `tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`.
   - §6.1 Existing capital (~:356): deleted
     `terraform-provider-smalt/scripts/schema_inventory_gate.py` → live
     `/Users/sac/smalt/scripts/posh_coverage.py` (`just posh-coverage`) +
     `adapters/terraform-provider-smalt` (G13 close). Description matches
     the script's actual behavior (surface inventory from
     `internal/provider`, pass/registered-divergence/loudly-missing cells,
     exit 1; verified against `scripts/posh_coverage.py` header, POSH-009).
   - §6.1 non-vacuity + Go-schema-leg paragraphs: rewritten honestly —
     `--self-test`/`bogus_attr_lx16` was the archived spike's mechanism;
     no `--self-test` in posh_coverage.py; no `provider_schema.go` exists
     in `internal/provider/` (checked on disk) — marked design target,
     not yet live.
3. `/Users/sac/smalt/docs/jira/posh/v26.10.30/gaps/09-courts-matrix.md`
   (~:37): "re-runnable via `just provider-court-elixir`" → NOT
   re-runnable post-tombstone. Verified:
   `justfile.d/57-tf-provider.just:77-80` exits 4 (`[TF-ARCHIVED]`,
   mix.exs absent) before the ladder starts. Run-once receipt stands;
   re-runnable stub lands with lane 51 (57 stub).
4. G26 turnstile caveat added to both:
   - `/Users/sac/smalt/docs/jira/posh/v26.10.30/working-backwards.md`
     (Receipt bullet in Engineering FAQ anchors)
   - `/Users/sac/smalt/docs/jira/posh/v26.10.30/requirements-synthesized.md`
     (clause 6, Receipt law)
   Both now state: receipt STAMP is ALIVE (X-Smalt-Receipt-Turnstile
   header + posh-smalt-wire assert); the FENCE (refuse unreceipted delta +
   settle into event log) is enforced nowhere live until lane 39 lands.

## Verification

- Every path cited exists on disk (checked with ls): README.md,
  design.md, 09-courts-matrix.md, scripts/posh_coverage.py,
  adapters/terraform-provider-smalt (internal/provider, scripts,
  scripts/receipts/{provider-court,c2-honesty-law}-2026-10-30.md),
  justfile.d/57-tf-provider.just.
- Deleted-path claims verified absent before asserting stale:
  `/Users/sac/smalt/terraform-provider-smalt/` and
  `.../scripts/schema_inventory_gate.py` — No such file or directory.
- No history deleted; all edits are additive/annotative with dates.
- Docs-only lane: no code touched, no gates affected.

## Open items (other lanes)

- Lane 39: live receipt fence (G26 closes then).
- Lane 51: re-runnable 57 stub → flips 09-courts-matrix row back to
  re-runnable.
