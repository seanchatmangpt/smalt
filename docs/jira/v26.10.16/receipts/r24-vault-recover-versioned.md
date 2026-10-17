# Receipt — R24 (vault soft-delete / recover restores versioned material)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave W2)
- **Standing:** PASS
- **Date:** 2026-10-15 (witnessed by W2 docs lane)

## Subject files

- `lib/smalt/data_plane/key_vault_actions.ex` — soft delete
  (`:smalt_vault_deleted_keys` table, `recoveryId`/`deletedDate`/
  `scheduledPurgeDate` bundle), recover restores the exact per-version
  material (version rows ride along in the deleted record).
- `test/data_plane/key_vault_actions_test.exs:710` —
  `"recover restores live version rows: versioned fetch returns the material (R24/A3-D1)"`.

## Verification (2026-10-15, W2 docs lane, unedited output)

```
$ mix test test/data_plane/key_vault_actions_test.exs > /tmp/kv.out 2>&1; echo "exit=$?"; tail -2 /tmp/kv.out
exit=0
42 tests, 0 failures
```
