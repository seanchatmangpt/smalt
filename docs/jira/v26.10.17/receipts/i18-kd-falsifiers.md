# I18: KD79 / KD87 falsifier suites

Standing: PASS (6 tests, 0 failures)

Lane I18, lease test/ (verify-only). Command:

```
MIX_BUILD_ROOT=_build-lane18 mix test test/kd79_blob_apiversion_wire_test.exs test/arm/kd87_sts_leading_empty_segment_test.exs
```

## Real output (2026-10-17, lane I18, build root _build-lane18)

```
14:48:28.135 [warning] SHIM-COURT affidavit-seal: :PQC_NOT_PROVISIONED witness-absent for /subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/kd79-rg/providers/microsoft.storage/storageaccounts/kd79store (engine_unavailable)
14:48:28.135 [info] Sent 202 in 715µs
14:48:28.135 [info] PUT /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/kd79-rg
14:48:28.135 [info] Sent 201 in 89µs
.
14:48:28.136 [info] PUT /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/kd79-rg/providers/Microsoft.Storage/storageAccounts/kd79store
14:48:28.136 [warning] SHIM-COURT affidavit-seal: :PQC_NOT_PROVISIONED witness-absent for /subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/kd79-rg/providers/microsoft.storage/storageaccounts/kd79store (engine_unavailable)
14:48:28.136 [info] Sent 202 in 546µs
14:48:28.136 [info] PUT /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/kd79-rg
14:48:28.136 [info] Sent 201 in 95µs
14:48:28.137 [info] PUT /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/kd79-rg/providers/Microsoft.Storage/storageAccounts/kd79store/blobServices/default
.
14:48:28.137 [info] Sent 400 in 79µs

Finished in 0.1 seconds (0.00s async, 0.1s sync)
6 tests, 0 failures
```

## Interpretation

- KD79 (blob api-version wire): real ARM PUT round-trips over live Bandit
  routers; storage-account PUT answered 202+201, blobServices PUT answered
  400 as the falsifier expects. Both suites green — no regression on either
  KD surface.
- KD87 (STS leading empty segment): included in the same run, 0 failures.
- The `SHIM-COURT affidavit-seal :PQC_NOT_PROVISIONED witness-absent`
  warnings are the expected engine_unavailable witness path, not failures.
