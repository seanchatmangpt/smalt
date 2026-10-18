# i21-full-suite-postfix — full quiet offline suite after the six i21 fix receipts

Standing: **PARTIAL_ALIVE** — suite executed to completion; 2655 tests ran, 4 failures, all four are drift-fence staleness failures (generated docs/projections vs sources), not behavioral. No edits, no git (per lane contract).

## Precondition: fix receipts present

Polled every 90s (two poll windows, ~8 tries total); all six present before the run. None MISSING:

- `docs/jira/v26.10.17/receipts/i21-fence10-fix.md`
- `docs/jira/v26.10.17/receipts/i21-ets-race-fix.md`
- `docs/jira/v26.10.17/receipts/i21-lro-face.md`
- `docs/jira/v26.10.17/receipts/i21-brokerfacade-sweeper.md`
- `docs/jira/v26.10.17/receipts/i21-blob-budget.md`
- `docs/jira/v26.10.17/receipts/i21-churn-budget.md`

## Command

```
MIX_BUILD_ROOT=_build-ft-full2 mix test > /tmp/i21-full-suite.out 2>&1
```

Full output: `/tmp/i21-full-suite.out` (129,529 lines).

## Real tail (verbatim)

```
  1 doctest, 7 properties, 2655 tests, 4 failures (61 excluded)
```

Mix exit code: 2 (from `echo "exit=$?"` after the run). The 61 excluded are the suite's typed exclusions.

## Failure identities (verbatim)

### 1. ERROR_CODES.md drift fence — `Smalt.ErrorCodesDocTest`

```
  1) test docs/ERROR_CODES.md is the byte-identical projection of the sources (Smalt.ErrorCodesDocTest)
     test/error_codes_doc_test.exs:46
     docs/ERROR_CODES.md is stale relative to the sources.
     Regenerate: python3 scripts/gen_error_codes.py
     Generator output:
     docs/ERROR_CODES.md is stale. Run: python3 scripts/gen_error_codes.py
     --- docs/ERROR_CODES.md (on disk)
     +++ regenerated
     @@ -21,83 +21,84 @@
```

The diff body is a wholesale shift of `lib/smalt/arm_gateway/router.ex:LINE` and `lib/smalt/egress_router.ex:LINE` citations (e.g. `router.ex:1309`, `router.ex:958`, `egress_router.ex:1308` all remapped), consistent with the i21-fence10 fix editing `lib/smalt/arm_gateway/router.ex` and moving lines.

### 2. cite-drift fence — `ApiVersionMatrixTest`

```
  2) test cite-drift fence: every router.ex:LINE citation resolves to the expected construct (ApiVersionMatrixTest)
     test/apiversion_matrix_test.exs:421
     stale citation lib/smalt/arm_gateway/router.ex:2725: expected line content matching "Microsoft.Network/virtualNetworks/:parent/subnets/:name" but got "          [{\"__unmatched__\", \"\"}]"
     code: for {cite, expected} <- @cite_drift do
     stacktrace:
       test/apiversion_matrix_test.exs:431: anonymous fn/3 in ApiVersionMatrixTest."test cite-drift fence: every router.ex:LINE citation resolves to the expected construct"/1
       (elixir 1.19.5) lib/enum.ex:2520: Enum."-reduce/3-lists^foldl/2-0-"/3
       test/apiversion_matrix_test.exs:427: (test)
```

### 3. capabilities.json drift fence — `Smalt.CanonicalProjectionTest`

```
  3) test generated artifact drift fence docs/capabilities.json equals rendered json/0 (Smalt.CanonicalProjectionTest)
     test/canonical_projection_test.exs:125
     docs/capabilities.json is stale vs Registry truth
     code: assert on_disk == Canonical.json(), "docs/capabilities.json is stale vs Registry truth"
     stacktrace:
       test/canonical_projection_test.exs:130: (test)
```

### 4. THIRD_PARTY.md drift fence — `Smalt.CanonicalProjectionTest`

```
  4) test THIRD_PARTY rider (E4 #6/#5b) docs/THIRD_PARTY.md equals third_party_markdown/0 byte-for-byte (Smalt.CanonicalProjectionTest)
     test/canonical_projection_test.exs:145
     docs/THIRD_PARTY.md is stale vs mix.lock truth — run Canonical.write/0
     code: assert File.read!(path) == Canonical.third_party_markdown(),
     stacktrace:
       test/canonical_projection_test.exs:151: (test)
```

## Analysis

- Failures 1+2: both fences cite `lib/smalt/arm_gateway/router.ex` by line number; the i21-fence10 fix shifted those lines and the fences correctly refuse. Closure is mechanical regeneration (`python3 scripts/gen_error_codes.py`, update `@cite_drift` line refs), not source repair.
- Failures 3+4: `docs/capabilities.json` / `docs/THIRD_PARTY.md` stale vs Registry/mix.lock — consistent with today's `mix.lock`/`mix.exs` churn (commit 8dad54f, ex4pm pin) landing after the last `mix run -e 'Smalt.Projection.Canonical.write()'`. Closure: `mix run -e 'Smalt.Projection.Canonical.write()'`.
- Zero behavioral failures: the six fix surfaces (store_dets ETS race, broker facade sweeper, blob budget, churn budget, LRO face, fence10) show no failing tests in this run.

## Transient observed during lane (pre-existing, not session-introduced)

Two initial attempts aborted pre-test with a mix dep-resolution error: `the dependency ex4pm 26.10.8 ... does not match the requirement specified ... In deps/ash_ex4pm/mix.exs: {:ex4pm, "26.10.1"}` — while `mix.lock` on disk pinned ex4pm 26.10.1, `git status` showed mix.exs/mix.lock clean, and `mix deps` showed both `ash_ex4pm 26.10.4` and `ex4pm 26.10.1` locked and converged. Suspected concurrent-lane mix churn during the fan-out; the retry resolved cleanly. Recorded for honesty; not reproduced at run time.

## SUPERSEDED-IN-PART (coordinator, 2026-10-17 21:5x)

All 4 drift-fence failures named above were subsequently fixed and
re-verified green: ERROR_CODES regen + Canonical.write riders + 10 cite
re-anchors → `mix test test/apiversion_matrix_test.exs
test/error_codes_doc_test.exs test/canonical_projection_test.exs` →
**268 tests, 0 failures** (committed 9c74de3). No behavioral failures
existed in this run; the six i21 fix surfaces ran clean.
