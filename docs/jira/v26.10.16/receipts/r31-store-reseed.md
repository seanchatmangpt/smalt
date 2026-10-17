# R31: store reseed

Standing: PASS
Lane: R16 docs (W2 found no landed diff; diff has since landed — receipt written W4)
· 2026-10-16
Surface: `lib/smalt/store.ex` (+62 diff), `lib/smalt/store/dets_mirror.ex` (+1)

## Claim

Store reseed/rebuild path repaired. W2's receipt note ("no landed changes found") is
superseded: the working tree now carries a 62-line store.ex diff.

## Re-run evidence

```
$ mix test test/store_churn_test.exs test/store_dets_test.exs
Finished in 9.0 seconds
21 tests, 0 failures
```

## Verdict

PASS. 21/0 over store churn + DETS mirror.
