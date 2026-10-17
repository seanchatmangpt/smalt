# Receipt — R116 (telemetry GenServer deleted-table hold)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `lib/smalt/telemetry.ex` (rolling-counter GenServer no longer crashes on a
  concurrently deleted table — repair marker `test/telemetry_test.exs:214`)
- `test/telemetry_test.exs`

## Repair

The telemetry GenServer held a reference to a deleted `:smalt_rolling_counters`
table across a test's delete/recreate cycle; the repair makes the GenServer
survive table loss (SHIM-COURT-free repair, recorded at
`test/telemetry_test.exs:214`). This also un-blocks the r92/r105/r106 W3/W4
open defect (dump/0 crash after table loss).

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/telemetry_test.exs test/data_plane/cosmos_test.exs test/data_plane/key_vault_actions_test.exs
181 tests, 0 failures
```

(The r92/r105/r106 W3/W4 known flake — table-loss test deleting
`:smalt_rolling_counters` without recreating it — did not reproduce under this
run; telemetry tests are green inside the 181-test batch.)
