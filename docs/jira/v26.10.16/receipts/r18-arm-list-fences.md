# Receipt — R18 (ARM list fences: deny-by-default before type projections)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave W2)
- **Standing:** PASS
- **Date:** 2026-10-15 (witnessed by W2 docs lane)

## Subject files

- `lib/smalt/arm_gateway/router.ex` — R18 fences added at the two type-scoped
  LIST projections (`GET /subscriptions/:sub_id/providers` and the
  provider-type-scoped resource LIST): `Enum.filter(&renderable_record?/1)`
  plus a binary-"type" filter before `String.split/1` / `&1["type"]` reads.
  (Same diff also carries R30's RG location-immutability 400 and the
  delete-nonexistent-RG 404 — receipted separately by their owning lanes.)

## Defect

A poisoned store row (non-map record, or a map without a binary `"type"`)
under the subscription prefix crashed the `&1["type"]` projection, 500-ing
the whole provider inventory / type-scoped LIST (store-poisoning DoS).

## Verification (2026-10-15, W2 docs lane, unedited output)

```
$ mix test test/smalt_arm_gateway_test.exs > /tmp/r18.out 2>&1; echo "exit=$?"; tail -2 /tmp/r18.out
exit=0
26 tests, 0 failures
```

Note: the dispatch brief projected "34 tests, 1 pre-existing failure"; the
actual suite on the current tree is 26 tests, 0 failures, exit 0 — better
than claimed. No failure to excuse.
