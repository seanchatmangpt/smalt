# Wire-incident replay corpus

Permanent evals for CLOSED wire incidents: every incident that was
diagnosed, fixed, and receipted on a wire surface gets a corpus module
asserting the fixed shape cannot regress.

## Corpus contract

1. Corpus families fence LANDED wire behaviors (incident → fix → fence on a
   real dispatch surface). The corpus↔KD mapping is tracked mechanically in
   `docs/jira/v26.10.16/sdk-results/wire-replay-census.json`; systematic
   CLOSED-KD fencing (every CLOSED KD row backed by a corpus family) is
   next-window roadmap — not a claim this corpus makes today.
2. Every corpus row cites its incident (receipt or fix site) in an
   `INCIDENT → FIX → FENCE` moduledoc triad at the top of the file.
3. Rows are real wire dispatches (Plug.Test against the real routers +
   real Store — Chicago, no mocks), tagged `:corpus`.
4. `test/corpus_test.exs` loads and runs the whole corpus in one
   invocation and fences the contract itself: inventory (all families
   present), dead-citation (each cited lib/ fix site still exists), and
   file layout.

## Run

```bash
mix test test/corpus_test.exs
```

## Families

| File | Incident | Fix site |
|---|---|---|
| `api_version_admission.exs` | KD-78 azurerm 4.54 api-version cap (tf-plan-probe) | `ArmGateway.Router.check_version/3` monotonic admission |
| `blob_container_reput.exs` | duplicate Put Container silently replaced the record (WORM clock reset) | `EgressRouter.container_reput_arm` (identical meta 200 / different 409, WORM gates first) |
| `head_database_account_names.exs` | azurerm CheckNameExists HEAD 400 + JSON body on HEAD | `ArmGateway.Router` HEAD databaseAccountNames (204/404 empty, no api-version) |
| `secret_cross_plane_seed.exs` | ARM secret PUT invisible on the data plane | `ArmGateway.Router.seed_data_plane_secret/4` |
| `cosmos_arm_container.exs` | ARM cosmos children not seeded to the data plane; pk unenforced | `ArmGateway.Router.seed_cosmos_child` + `PartitionKey.enforce` |
| `vault_enrichment.exs` | azurerm 4.54 FR-5 sparse-record derefs (vaultUri, primaryEndpoints) | `ArmGateway.Defaults.enrich/5` |
| `eh_created_at.exs` | EH namespace `created_at` snake_case typo vs SB `createdAt` | `ArmGateway.Defaults` enrichment tables |
| `tags_normalization.exs` | azurerm `"tags": null` echoed, terraform persistent diff | `ArmGateway.Router.normalize_tags/1` |
| `shacl_fuzz.exs` | no adversarial receipt for the Validate∘Hydrate PUT pipeline (untyped escapes / refusal mutations unproven) | `ArmGateway.Router` "Defaults hydrate BEFORE shape validation" + typed refusal envelopes |

## Adding a family

New CLOSED incident → new `test/corpus/<family>.exs` with the
INCIDENT → FIX → FENCE triad, `@tag :corpus` on every test, and a row
in the table above plus entries in `test/corpus_test.exs`
(`@corpus_modules`, `@fix_sites`, `corpus_files`). The corpus is part
of the default `mix test` tier.
