# R26: sentinel KQL repair

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/data_plane/sentinel.ex` (+53 diff), `lib/smalt/data_plane/kql.ex` (+30)

## Claim

Sentinel/KQL defects from the audit wave repaired; sentinel queries parse and route
through the KQL surface.

## Re-run evidence (re-run by this lane, not trusted from lane reports)

```
$ mix test test/data_plane/kql_test.exs test/data_plane/audit_planes_test.exs test/data_plane/key_vault_actions_test.exs
.................................................................................................................................................
Finished in 2.1 seconds (0.5s async, 1.6s sync)
145 tests, 0 failures
```

## Verdict

PASS. 145/0 across the KQL + audit-planes (sentinel) + KV batch. `git diff --stat` confirms
landed changes on both files (sentinel.ex +53, kql.ex +30).
