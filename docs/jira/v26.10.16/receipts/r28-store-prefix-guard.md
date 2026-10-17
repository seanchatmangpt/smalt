# Receipt — R28 (Store.prefix_keys binary-prefix guard fixup)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave W2)
- **Standing:** PASS
- **Date:** 2026-10-15 (witnessed by W2 docs lane)

## Subject files

- `lib/smalt/store.ex` — `prefix_keys/2` raises `ArgumentError` on a
  non-binary PREFIX argument (fail-loud caller contract, SHIM-COURT-tagged)
  while restoring the original silent-skip for non-binary KEYS in the table
  (mixed-type `key >= prefix` comparisons drop silently in term order);
  `clear/0` re-seeds the default subscription via the extracted
  `seed_default_subscription/0`.

## Defect

The first cut raised on non-binary KEYS too, breaking legitimate tuple-keyed
rows (`{name, version}` vault rows, `{:latest, _}`, `{db, coll}`); the fixup
narrows the raise to the PREFIX argument only.

## Verification (2026-10-15, W2 docs lane, unedited output — freeze-clear re-run)

```
$ mix test test/store_churn_test.exs > /tmp/r28b.out 2>&1; echo "store-exit=$?"; tail -2 /tmp/r28b.out
store-exit=0
15 tests, 0 failures
```

Note: the dispatch brief's "122 tests" figure did not match any single suite
on disk (store_churn is 15 tests); the reproducible command-level witness
above is the record. One earlier witness attempt collided with another
lane's in-flight `blob_service.ex` edit (shared-tree compile freeze, 0 tests
executed) — compile-freeze SLA, no cross-lane fix applied by this lane.
