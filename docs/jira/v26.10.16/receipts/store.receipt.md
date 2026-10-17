# Receipt — store_tables (W1b StoreTable projection replay fence)

- **Subject:** `/Users/sac/smalt` @ main, HEAD `650a8ff`
- **Standing:** PASS
- **Date:** 2026-10-17

## Subject files

- `lib/smalt/store_tables.ex` (generated, DO-NOT-EDIT)
- `test/store_tables_replay_identity_test.exs` (fence)
- `ggen-marketplace/packs/smalt-substrate-pack` (StoreTable rows)

## Verification (2026-10-17, I2 lane, unedited output)

```
$ mix test test/store_tables_replay_identity_test.exs ; echo "exit=$?"
Running ExUnit with seed: 132198, max_cases: 32
Excluding tags: [:amqp_wire]

....
Finished in 4.6 seconds (0.00s async, 4.6s sync)
4 tests, 0 failures
exit=0
```

## Non-vacuity

Arm 1 re-renders `store_tables.ex` from the pack checkout and byte-compares
against the on-disk artifact (a hand-edit flips it); arm 2 asserts the
pack-lock digest matches the pinned digest (a stale pack flips it); the
`ownerModule` gate asserts every `:smalt_*` atom in `lib/` has an owning
row (the swept-but-unowned blob_blocks class — an unowned atom flips it).
Each arm can exit 1.
