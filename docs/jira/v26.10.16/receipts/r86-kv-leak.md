# R86: Key Vault leak

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/data_plane/key_vault_actions.ex` (+394 diff)

## Claim

Key Vault secret/leak repairs landed (no credential material in responses).

## Re-run evidence

```
$ mix test test/data_plane/kql_test.exs test/data_plane/audit_planes_test.exs test/data_plane/key_vault_actions_test.exs
Finished in 2.1 seconds (0.5s async, 1.6s sync)
145 tests, 0 failures
```

## Verdict

PASS. 145/0 batch (KV + KQL + audit planes). KV TLS challenge leg additionally green in
r90 (26/0).
