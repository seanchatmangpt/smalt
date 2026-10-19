# i26 — Canonical projection residual drift (capabilities.json)

Standing: PASS
Context: pair(test/error_codes_doc_test.exs, test/canonical_projection_test.exs) under MIX_BUILD_ROOT=_build-ft-canon

## Symptom

`MIX_BUILD_ROOT=_build-ft-canon mix test test/error_codes_doc_test.exs test/canonical_projection_test.exs`
→ `27 tests, 1 failure` (exit 1):

```
1) test generated artifact drift fence docs/capabilities.json equals rendered json/0 (Smalt.CanonicalProjectionTest)
   test/canonical_projection_test.exs:134
   docs/capabilities.json is stale vs Registry truth
   code: assert on_disk == Canonical.json(), "docs/capabilities.json is stale vs Registry truth"
   stacktrace:
     test/canonical_projection_test.exs:139: (test)
```

ERROR_CODES leg was already green.

## Diagnosis

Manifest drift: `docs/capabilities.json` differed from `Smalt.Projection.Canonical.json()`
in exactly two fields (pack registry sha256 values, lines 216-217):

```
216,217c216,217
<     "contentSha256": "917a002b3e47afe36e93de18858cb388480edfc904fa4fea6ed9f38939204ece",
<     "packLockSha256": "7beea18f77e31d4506e30dbcbe4eb68ab0eec5a6819cb0d91a4a75ea508ade06",
---
>     "contentSha256": "9e29250bf525d40dc0bc6f4bb1b5e51e35e2e5ac112b48a92eac88eef8d26f52",
>     "packLockSha256": "9cb0aded99689c5775d30de123317ba657de0127ec71bfdf33e749e35c66d714",
```

Root cause of the stale regen: `mix run -e 'Smalt.Projection.Canonical.write()'` boots the
full smalt app and fails fast with `:eaddrinuse` when the shared substrate holds the fixed
ports (witnessed: DataSupervisor → Bandit listener → `:eaddrinuse`), so the earlier regen
never wrote. Regeneration without booting listeners works:

```
$ MIX_BUILD_ROOT=_build-ft-canon mix run --no-start -e 'Smalt.Projection.Canonical.write()'
==> smalt
Compiling 3 files (.ex)
Generated smalt app
```

No source change needed; projection regenerated per generated-artifact policy
(never hand-edited).

## Verification (real gate)

```
$ MIX_BUILD_ROOT=_build-ft-canon mix test test/error_codes_doc_test.exs test/canonical_projection_test.exs
Finished in 1.5 seconds (0.00s async, 1.5s sync)
27 tests, 0 failures
```

## Notes

- Fix-forward, no git actions taken.
- Hazard worth a lane note: the Canonical.write rider is port-sensitive under the default
  `mix run` boot; `--no-start` is the substrate-safe invocation.
