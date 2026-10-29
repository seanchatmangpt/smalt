# Receipt: migrate-enterprise showcase fixture (MIGDEMO)

- Date: 2026-10-21
- Lane: writer (smalt-migrate Fortune-5 demo fixture)
- Repo: /Users/sac/smalt (canonical checkout, main)

## Subject

`smalt-cli/tests/fixtures/migrate-enterprise/` — 12-file mixed IaC estate
(8 Terraform + 4 Bicep), orders/payments/inventory domain shape, 66 supported
resource blocks + 6 deliberate unsupported-type occurrences + `${...}`
interpolations on both language legs for the typed-error paths.

Files: terraform/{variables,cosmos,storage,keyvault,messaging,events,apim,monitoring}.tf
+ bicep/{servicebus,eventhubs,apim,monitoring}.bicep.

Census test: `smalt-cli/tests/test_migrate_enterprise_fixture.py` (5 tests —
tree shape, per-type block counts, typed-unresolved interpolations, pipeline
end-to-end into tmp, live verify with loud SKIP).

README: `smalt-cli/README.md` "Showcase fixture" section — factual counts from
the measured pipeline run, replay snippet included.

## Commands + output

```
.venv-cli/bin/python -m pytest tests/test_migrate_enterprise_fixture.py \
  tests/test_migrate_scan.py tests/test_migrate_manifest.py \
  tests/test_migrate_inject.py tests/test_migrate_pipeline.py -q
# 43 passed in 3.53s

pipeline run_all(tests/fixtures/migrate-enterprise, /tmp/migdemo-out, /tmp/migdemo.env):
[scan] ok {'files_scanned': 12, 'resource_blocks': 66, 'scan_errors': 0,
           'unsupported_types': {Microsoft.Insights/actionGroups: 1,
            Microsoft.OperationalInsights/workspaces: 1,
            azurerm_application_insights: 1, azurerm_log_analytics_workspace: 1,
            azurerm_resource_group: 1, azurerm_storage_account: 1}}
[generate] ok {'seed_fixtures': 8, 'bytes': 37908}
[inject] ok {'services': ['blob','cosmos','eventhubs','keyvault','servicebus'], 'lines': 9}

.venv-cli/bin/python -m smalt_cli.migrate.verify --services blob,cosmos,kv,servicebus \
  --out /tmp/migdemo-receipt.json
# [smalt-migrate verify] PASS -> /tmp/migdemo-receipt.json
# zero_egress: true, hosts: ["127.0.0.1"], skipped: [] on all four services
```

## Falsifiers checked

- Interpolations surface typed `unresolved`, not guessed (asserted on both
  the tf leg `cosmos-orders-${var.environment}` and bicep
  `sb-partners-${envName}`).
- Unsupported types are counted, never silently dropped (asserted absent from
  blocks, present in `unsupported_resource_types`).
- Parser regression fence: any extractor change shifting the census fails
  `test_census_blocks_by_type`.

## Notes / limitations observed (pre-existing, not session-introduced)

- Bicep parser drops attributes whose value line carries a trailing `//`
  comment (fixture comments moved to their own lines to work around it).
- Bicep `sku.name` flattens to tf-shaped `sku` (asserted in census).
- `eventhubs` is not a registered verify VERIFIERS key (blob/cosmos/kv/
  servicebus are); the live leg covers the registered set.

## Standing

**Standing:** ALIVE — census tests green on the exact fixture tree; real pipeline scan ->
generate -> inject executed into /tmp; live verify PASS against the running
loopback substrate with zero non-loopback egress. Receipt context: solo.
