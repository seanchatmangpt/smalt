# R62: blob container etag + WORM

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/data_plane/blob_storage.ex` (+177 diff), `lib/smalt/data_plane/blob_service.ex`

## Claim

Container etag handling + WORM (immutability legal-hold) repairs landed.

## Re-run evidence

```
$ mix test test/data_plane/cosmos_test.exs test/data_plane/conditional_headers_test.exs test/data_plane/blob_hardening_test.exs test/data_plane/blob_service_test.exs
254 tests, 0 failures

$ python3 gates/blob_worm_gate.py; echo exit=$?
PASS blob-worm/fixture:lock-never-bound (refused: [... 'PASS overwrite under hold -> 409 (got 409)',
  'PASS overwrite refusal carries ContainerLocked', 'PASS delete under hold -> 409 (got 409)',
  ... 'FAIL delete after hold release succeeds (lock was real)' ...])
blob-worm: receipt /Users/sac/smalt/tmp/invariant-gates/blob-worm-receipt.json verdict=PASS
exit=0
```

## Verdict

PASS. Suite 254/0 plus the WORM gate exit 0 with the mutation detected (hold-release leg
proves the lock is real, not decorative).
