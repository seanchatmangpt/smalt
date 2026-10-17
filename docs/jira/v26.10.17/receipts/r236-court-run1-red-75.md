# r236 — court run-1 RED: 75 failures at T1 offline (milestone-doc lane)

Date: 2026-10-17. Repo: /Users/sac/smalt. Source log:
`tmp/court-x2-v17-run1.log` (87,019 lines). Invocation: `just court-x2`
run 1, offline tier only (`Excluding tags: [:amqp_wire]`).

Standing: **RED (honest)** — the run failed; this receipt documents the red
witness, it does not close it.

## 1. Run header and tail (real log lines)

```
Running ExUnit with seed: 71461, max_cases: 32
Excluding tags: [:amqp_wire]
```

```
Finished in 422.8 seconds (19.5s async, 403.3s sync)
1 doctest, 7 properties, 2655 tests, 75 failures (61 excluded)
error: recipe `test-offline` failed on line 85 with exit code 2
COURT_RC=2
```

Doctor preflight passed before the tier ran:

```
=== SMALT DOCTOR DIAGNOSTIC COURT (v2) ===
[PASS] binaries (0.2ms): ok
[PASS] port-arm (0.1ms): ok
[PASS] port-data (0.0ms): ok
[PASS] port-amqp (0.0ms): ok
```

Exit 2 = test failures (not substrate-down / harness-skip).

## 2. Failure table by module (grep-derived, sums to 75)

Extracted from the numbered failure lines in the source log
(`grep -E "^\s+[0-9]+\) test" | sed module | sort | uniq -c | sort -rn`):

```
  19 Smalt.Compliance.C4BlobTest
  15 Compliance.C2KeyvaultTest
  12 Smalt.PolicyRbacTest
   6 SmaltServicesTest
   6 Smalt.Compliance.C1ArmTest
   5 EgressDispatchTest
   4 Kd79BlobApiVersionWireTest
   2 Smalt.Corpus.SecretCrossPlaneSeed
   2 Smalt.Corpus.CosmosArmContainer
   1 Smalt.EventGridTopicsArmTest
   1 Smalt.EtsCompositeIdentityTest
   1 Smalt.Compliance.C7EventsTest
   1 ApiVersionMatrixTest
```

13 modules, total 75. Notably **zero** failures in
`Smalt.AshExtensionTest` — the ash_extension surface is fully green in this
run; see §4.

## 3. Representative failure detail (verbatim, failure 1 of 75)

```
  1) test GET validates api-version like PUT (row 6b fixed): bogus GET api-version -> 400 (Smalt.Compliance.C1ArmTest)
     test/compliance/c1_arm.exs:599
     ** (MatchError) no match of right hand side value:

         {404,
          %{
            "access-control-allow-credentials" => "true",
            "access-control-allow-origin" => "*",
            ...
            "content-type" => "application/json; charset=utf-8",
            "date" => "Sat, 17 Oct 2026 21:48:08 GMT",
            ...
          },
          "{\"error\":{\"code\":\"ResourceNotFound\",\"innererror\":{},\"message\":\"The Resource 'stc1x' was not found.\",\"target\":\"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/stc1x\"}}"}

     code: {400, _h, body} = get!(port, resource_path("stc1x", "1999-01-01"))
     stacktrace:
       test/compliance/c1_arm.exs:602: (test)
```

(expected 400 InvalidApiVersionParameter; observed 404 ResourceNotFound —
the resource the test's own setup should have created was absent.)

## 4. The DslError red herring

The log contains prominent `Spark.Error.DslError` stack traces (9
occurrences), e.g. verbatim:

```
warning: ** (Spark.Error.DslError) substrate :
  smalt substrate_resource: store_table :bogus_table is outside the smalt_ Store table namespace
    (elixir 1.19.5) lib/process.ex:900: Process.info/2
    (spark 2.7.8) lib/spark/error/dsl_error.ex:35: Spark.Error.DslError.exception/1
    (smalt 26.10.16) lib/smalt/ash_extension/generated_verify.ex:94: Smalt.AshExtension.SubstrateResource.Verify.check_table_name/1
```

These are **not** among the 75 failures. They are printed warnings emitted
by the ash_extension refusal tests' EXPECTED specimens: the verifier
correctly refuses bad source during `Code.compile_string/1` inside
`compile_refused/2` (`test/ash_extension_test.exs:105-138`), which asserts
the refusal is witnessed as EITHER a raised `Spark.Error.DslError` matching
the expected regex OR a captured error diagnostic matching it — a clean
compile with neither means the verifier is vacuous. The warnings are the
mechanism working, printed to stderr by the Elixir 1.19 parallel checker;
the ash_extension test module itself shows 0 failures (§2). Do not chase
these traces as regressions.

## 5. Failure classes and the two live hypotheses

401-class artifacts are present in the run (verbatim):

```
    create c2-oct-15875 returned 401: "{\"error\":{\"code\":\"AuthenticationFailed\",\"message\":\"MissingBearerToken\"}}"
    create c2-azure-pol-14027 returned 401: "{\"error\":{\"code\":\"AuthenticationFailed\",\"message\":\"MissingBearerToken\"}}"
    parent SA creation failed: 401
```

These match the cross-file interference signature first witnessed by lane
I3 (`receipts/i3-witness-sweep.md` §4): running multiple test files in ONE
mix invocation produced "321 tests, 71 failures, all 401/MissingBearerToken-class
cross-file shared-state artifacts — e.g. `Kd79BlobApiVersionWireTest` setup:
'parent SA creation failed: 401'"; every one of those files is green solo,
and I3's falsifier note says "Batched (multi-file) mix invocations are NOT
valid witnesses for these surfaces."

Live hypotheses, both unfalsified by run-1:

- **H1 — cross-file auth-state interference (I3's batched-run finding)**:
  the full-suite run is exactly the batched context I3 flagged; the 401
  MissingBearerToken cluster (C2Keyvault 15, parts of Kd79/PolicyRbac) and
  downstream setup-cascade 404s (e.g. §3's missing resource) would all be
  shared-state artifacts, and the true product surface may be green.
- **H2 — product 401 from the KD-87 shims in flight**
  (`lib/smalt/arm_gateway/router.ex:85-86`, `lib/smalt/auth/bearer.ex:180`;
  per I3 §1 those exact shims pass their own file solo, 2 tests / 0
  failures): if the shims mis-authorize some request shape only exercised
  under full-suite ordering, the failures are real product regressions to
  fix in lib/, not test hygiene.

Also real and NOT 401-class: the `ApiVersionMatrixTest` cite-drift failure
(router.ex line citation drifted — expected
`"Microsoft.Network/virtualNetworks/:parent/subnets/:name"`, got `""` at
`lib/smalt/arm_gateway/router.ex:2714`), consistent with in-flight lib/
edits shifting lines; and the I3-§4a deterministic envelope-drift classes
(C1Arm api-version envelope shape, C4Blob x-ms-version copy / conditional
HEAD codes) plausibly persisting into the full run.

## 6. Diagnostic lanes dispatched

To split H1 vs H2, three lanes are prescribed (dispatched this window):

1. **Seed-rerun lane**: repeat the identical offline tier with a different
   seed and compare the per-module failure table. If the 401-cluster module
   set is stable it stops looking like pure scheduling interference.
2. **Solo-bisect lane**: rerun each of the 13 failing modules in its own
   `mix test` invocation (per I3's per-file witness protocol). Modules green
   solo → H1 artifacts; modules red solo → H2 evidence with a minimal
   repro file.
3. **Shim-ablation lane**: revert the two KD-87 shim lines on a scratch
   copy (`git show HEAD:lib/smalt/auth/bearer.ex > /tmp/...` snapshot swap,
   never stash) and rerun the worst module (C4Blob) solo; a flip back to
   green implicates the shims (H2) with the shim-court BASELINE/BEFORE/
   AFTER/RESTORE discipline.

## 7. Replay

```
grep -E "^\s+[0-9]+\) test" tmp/court-x2-v17-run1.log
tail -5 tmp/court-x2-v17-run1.log   # summary + COURT_RC=2
```
