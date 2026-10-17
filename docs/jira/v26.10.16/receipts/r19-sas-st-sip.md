# Receipt — R19 (SAS st/sip: start-time window + IP-range claims)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave W2)
- **Standing:** PARTIAL_ALIVE
- **Date:** 2026-10-15 (witnessed by W2 docs lane)

## Subject files

- `lib/smalt/auth/sas.ex` — parses/verifies blob-account-SAS query params
  including `st` (shared-access start time, `parse_start/1` window check) and
  `sip` (authorized-IP range claim); `test/data_plane/blob_hardening_test.exs`
  is the court (109 tests, incl. `Sas.mint` round-trips).

## Defect

Blob-account-SAS requests did not honor the `st`/`sip` claims.

## Verification (2026-10-15, W2 docs lane, unedited output — two runs, both exit 2)

```
$ mix test test/data_plane/blob_hardening_test.exs > /tmp/r19.out 2>&1; echo "exit=$?"; tail -2 /tmp/r19.out
exit=2
109 tests, 1 failure
```

Failure (reproduced identically on both runs, minutes apart):

```
  1) test ST6 D1 — binary blob PUT is content-leak-free container create with
     metadata: set at create, replace semantics, hostile 400 pre-create
     (Smalt.DataPlane.BlobHardeningTest) — test/data_plane/blob_hardening_test.exs:819
     match (=) failed
       left:  {:ok, %{"team" => "platform", "env" => "prod"}}
       right: {:ok, %{}}
     code: assert {:ok, %{"team" => "platform", "env" => "prod"}} =
             BlobService.get_container_metadata("acc1", "create-meta")
```

The failure is container-metadata set-at-create (`get_container_metadata`
returns `%{}`), not the st/sip SAS claims. Claimed "109 tests, 0 failures"
does NOT reproduce on the current tree. Open defect: blob container
metadata set at create time is not returned by `get_container_metadata/2`
(`blob_service.ex` surface — blob_service.ex was concurrently in-flight
under another lane during this witness; re-verify after that lane lands).
