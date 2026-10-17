# Witness receipt — KD-04 InvalidQueryParameter → InvalidQueryParameterValue token rename

Standing: **PASS** (code rename landed in lib/, zero stale tokens, green tests)

- Date: 2026-10-17, KD-register lane.
- Scope of the landed change (working tree, uncommitted): every wire token
  `InvalidQueryParameter` renamed to `InvalidQueryParameterValue` across
  `lib/smalt/egress_router.ex`, `lib/smalt/data_plane/blob_storage.ex`,
  `lib/smalt/data_plane/blob_service.ex` plus all test pins;
  `docs/ERROR_CODES.md` regenerated (107 rows).

## Grep evidence (real output)

```
$ grep -rn "InvalidQueryParameter\b" lib/ test/ | grep -v Value | wc -l
0
$ grep -rn "InvalidQueryParameterValue" lib/ | wc -l
10
```

Zero stale-token occurrences in lib/ and test/; 10 live
`InvalidQueryParameterValue` sites in lib/.

## Test evidence (real output)

```
$ MIX_BUILD_ROOT=_build-laneKD mix test test/egress_dispatch_test.exs \
    test/egress_kv_appconfig_test.exs test/data_plane/blob_hardening_test.exs
237 tests, 1 failure
```

The single failure is the KV soft-delete cycle test
(`test/egress_dispatch_test.exs:2819`, "delete -> get deleted -> recover ->
purge cycle") failing on its **key-create precondition** — `PUT
/keys/delkey1/create` answers 404 NotFound ("reserved namespace 'keys'") —
not on any error-envelope token; unrelated to KD-04 and owned by the
coordinator lane (see kd13-kd75-softdelete-routes-witness.md).

Blob/KV error-envelope surfaces all green:
`test/egress_kv_appconfig_test.exs + test/data_plane/blob_hardening_test.exs`
→ `130 tests, 0 failures`.

## Register mechanics

Code change, not a shim: no `# KD-COVERS` token, status stays OPEN pending
the next `kd_flip.py` pass.
