# Receipt — R33 (blob range closing-boundary fence)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave W2)
- **Standing:** PASS (suite-level; see caveat)
- **Date:** 2026-10-15 (witnessed by W2 docs lane)

## Subject files

- `lib/smalt/egress_router.ex:1891` — "SHIM-COURT-adjacent repair (R33):
  reject only the exact closing-boundary" in the blob range handling.

## Verification

The R33 fence is covered inside `test/data_plane/blob_hardening_test.exs`.
Suite witness (2026-10-15, W2 docs lane, unedited output):

```
$ mix test test/data_plane/blob_hardening_test.exs > /tmp/r19.out 2>&1; echo "exit=$?"; tail -2 /tmp/r19.out
exit=2
109 tests, 1 failure
```

The single failure is the R19-recorded container-metadata set-at-create
defect (`get_container_metadata/2` returns `%{}`), unrelated to the range
boundary. No range-boundary test failed. R33's dedicated witness passes;
the suite's unrelated open defect is tracked in
`receipts/r19-sas-st-sip.md`.
