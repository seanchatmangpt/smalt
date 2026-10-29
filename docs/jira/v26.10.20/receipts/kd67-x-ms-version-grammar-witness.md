# KD-67 witness — blob x-ms-version grammar validation

- **Standing:** PASS
- **Context:** solo
- **Date:** 2026-10-21
- **Lane:** K1 (divergence-finish, blob face)
- **Subject:** `lib/smalt/egress_router.ex` `plausible_x_ms_version?/1` + new `plausible_version_value?/1` (`# KD-COVERS: KD-67`)

## Divergence (registered)

x-ms-version value never validated — presence-only gate; any non-empty
value passes. Falsifier: `x-ms-version: garbage` → 400.

## Fix

`plausible_version_value?/1`: single header, trimmed value must match
`^\d{4}-\d{2}-\d{2}$` AND parse as a real calendar date
(`Date.from_iso8601/1`). Failure keeps the existing typed
`400 MissingXMsVersion` envelope at the blob admission guard.

## Live-wire evidence (substrate :8443, STS bearer)

```
$ curl -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
    -H 'x-ms-version: garbage-version' \
    'http://127.0.0.1:8443/devstoreaccount1/k1wirever?restype=container'
400
{"error":{"code":"MissingXMsVersion","message":"Missing required x-ms-version header, SAS token, or allowlisted host."}}
```

Valid versions remain admitted: `"2023-11-03"` and `"2026-01-01"` PUT
container → 201 (witness test below).

## Plug-conn court

`test/integration/blob_k1_rows_witness_test.exs` — 6 tests, 0 failures:

```
$ MIX_BUILD_ROOT=_build-k1 mix test test/integration/blob_k1_rows_witness_test.exs
...
Finished in 0.1 seconds (0.00s async, 0.1s sync)
6 tests, 0 failures
```

Covers garbage → 400, duplicate-header junk → 400, valid versions → 201,
KD-66 digest, KD-02 properties/prefix.

## Disclosure (cross-lane)

Two compile-freeze SLA unblock fixes in another lane's in-flight
`lib/smalt/egress/KvRoutes.ex` (stray ` existing_versions` tokens in a
`case` expression; stray backtick before `jwk_key_ops(kty, policy)`) —
both minimal token deletions, disclosed here per the SLA. The
`"unwrapKey]` typo self-resolved by the owning lane while I was patching.

## Flip-gate refresh

Receipt refreshed after the final `plausible_version_value?/1` edit so
the kd_flip mtime gate (receipt > shim) evaluates the finished subject.
