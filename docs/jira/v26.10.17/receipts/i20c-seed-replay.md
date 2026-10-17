# i20c — seed replay 71461 (measurement lane)

Standing: PARTIAL_ALIVE — replay completed, but the tree moved between runs, so this is NOT a clean seed-determinism measurement.

## Command

```bash
MIX_BUILD_ROOT=_build-ft-seed mix test --seed 71461 > tmp/seed-replay-71461-attempt3.log 2>&1
# RC=2
```

Log: `tmp/seed-replay-71461-attempt3.log` (attempt 3; attempts 1–2 are partial/contaminated — see caveats).

## Result

Attempt 3: 1 doctest, 7 properties, 2655 tests, **7 failures** (61 excluded), 735.2s (13.5s async, 721.6s sync), RC=2.

| # | Test | Module |
|---|------|--------|
| 1 | compliance rows cover every code the compliance corpus pins literally | Smalt.ErrorCodesDocTest |
| 2 | docs/ERROR_CODES.md is the byte-identical projection of the sources | Smalt.ErrorCodesDocTest |
| 3 | cite-drift fence: every router.ex:LINE citation resolves to the expected construct | ApiVersionMatrixTest |
| 4 | Sweeper run_pass/0 calls every sibling sweep directly (tolerate-absence retired, fail-closed) | Smalt.Amqp.BrokerFacadeTest |
| 5 | atlas entity/bulk dispatches (empty batch admits 201) — **ETS table `:smalt_subscriptions` missing at setup** | EgressDispatchTest |
| 6 | readback merges CloudEvents and EG1 events of one topic by seq | Smalt.EventGridTopicsArmTest |
| 7 | [eh] partitions are free-form names — no 0..N fan-out structure is enforced (PARTIAL fence) | Smalt.Compliance.C7EventsTest |

## Comparison vs run-1 (tmp/court-x2-v17-run1.log, same seed, 75 failures)

Run-1: C4Blob 19, C2Keyvault 15, PolicyRbac 12, SmaltServices 6, C1Arm 6, EgressDispatch 5, Kd79 4, rest singles.

**75 → 7.** Only 3 of 7 replay failures match run-1 by exact test name (C7Events PARTIAL fence, ApiVersionMatrix cite-drift, EventGridTopicsArm readback merge). The entire C4Blob/C2Keyvault/RBAC/C1Arm/SmaltServices/Kd79 failure mass (68 failures) is gone — concurrent lanes landed fixes for those surfaces between run-1 and this replay (git status shows blob_service.ex, bearer.ex, router.ex etc. modified during the window). The four replay-only failures (ErrorCodesDocTest x2, BrokerFacade sweeper, EgressDispatch ETS-missing) are new to this tree.

One failure is direct state-leakage evidence: EgressDispatchTest setup hits `:ets.insert(:smalt_subscriptions, ...)` → "table identifier does not refer to an existing ETS table" — a prior test's teardown removed a table a later test's setup assumes present; the fixture depends on shared-process ETS lifecycle, and async scheduling at any seed can break it.

## Caveats (load-bearing)

- **Tree moved.** Attempt 2 aborted outright with a compile error: `test/compliance/c4_blob.exs` was read mid-edit by a concurrent lane (+48/-17 in-flight, `get_resp_header/2` undefined at compile). The `get_resp_header` references are gone from the file now. So run-1 vs attempt 3 is tree-vs-tree, not seed-vs-seed.
- Fixed seed does not imply fixed async scheduling; even on an identical tree, ETS-lifecycle failures like the one above can flip either way at the same seed.
- First background attempt was killed at its 10-minute limit mid-suite; its partial output remains in `tmp/seed-replay-71461.log` along with attempt 2 (compile-abort, RC=1).

## Verdict

Same seed ≠ same outcome on this tree, but the dominant variable was tree drift, not seed. Within-attempt evidence (ETS table missing at setup) confirms non-deterministic state leakage is present at fixed seed. A clean measurement requires a frozen tree: snapshot the tree (`git archive` to /tmp) or run on a quiesced window — `git stash` is banned in this checkout.
