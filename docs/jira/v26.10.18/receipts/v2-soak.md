# Receipt: v2 soak — 3x full `mix test` + wire court 2x, on `_build-ft-v2`

Date: 2026-10-18 (runs 20:07–20:56 PDT) · HEAD c6f6243 → 24cb2cd mid-run (coordinator docs commits; all counted runs started at c6f6243 tree, no test-relevant diff between) · Context: full
Lane: bench-runner verification wave 2 (no edits, no git actions).
Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}` (`just bench-machine`)

## Gate

Polled `docs/jira/v26.10.18/receipts/v1-soak.md` (landed ~17:0x PDT) before run 1.

## Results (3 consecutive full runs, same tree, `MIX_BUILD_ROOT=_build-ft-v2`)

| Run | Log | Exit | Duration | ExUnit summary (verbatim) |
|---|---|---|---|---|
| 1 | `/tmp/v2-soak-run1.log` | 2 | 123.7 s (13.6 async / 110.0 sync) | `1 doctest, 7 properties, 2700 tests, 9 failures (93 excluded)` |
| 2 | `/tmp/v2-soak-run2.log` 26,343 lines | 2 | 106.7 s (15.1 async / 91.6 sync) | `1 doctest, 7 properties, 2700 tests, 9 failures (93 excluded)` |
| 3 | `/tmp/v2-soak-run3.log` | 2 | 101.6 s (14.2 async / 87.4 sync) | `1 doctest, 7 properties, 2700 tests, 8 failures (93 excluded) |

**Acceptance (3/3 zero-failure full pass) NOT MET: 3/3 RED, 0/3 green.**
93 excluded = `:amqp_wire` default exclusion. 2700 tests vs v1-soak's 2633 (+67 from
the day's batch landings).

## Wire court T1/T2 (`mix test test/wire --include amqp_wire`)

| Leg | Log | Exit | Summary |
|---|---|---|---|
| T1 | `/tmp/v2-wire-t1.log` | 0 | `29 tests, 0 failures` |
| T2 | `/tmp/v2-wire-t2.log | 0 | `29 tests, 0 failures` |

Wire court 2/2 CLEAN.

## Failure identities (unique faces across the 3 runs, 12 total)

| # | Face | Runs | File state |
|---|---|---|---|
| 1 | `Smalt.DSPy.RemediationTest` — parse/1 esc round-trip `** (MatchError) {"", 1}` (`test/dspy_test.exs:131→145`) | 1 | committed-clean |
| 2 | `EnclaveStateTest` — destroy residue `:smalt_sb_queues: ["resourcewritesuccess"]` (`test/enclave_state_test.exs:173→214`) | 1,2,3 (3/3) | committed-clean |
| 3 | `Smalt.McpWireTest :806` — doctor.summary `supervisor_children` missing `Smalt.Store` | 1,2 | committed-clean |
| 4 | `Smalt.McpTest :420` — same doctor.summary face as #3 | 1,2,3 | committed-clean |
| 5 | `SmaltTest.Azsim.TopologyTest` — ARM PUT ResourceWriteSuccess `body["data"]["resourceUri"] == uri` false (`test/azsim/topology_test.exs:141→187`) | 1,2 | committed-clean |
| 6 | `SmaltTest.Azsim.DetsRecoveryTest :234` — engine-killed mid-request, assert_eventually timeout (`:274`) | 1 | committed-clean every file I checked |
|7| `Smalt.Telemetry.EnclaveOcelTest` — one stage event per stage | 2,3 | committed-clean |
| 8 | `Smalt.Enclave.LifecycleTest` — composite baseline fixture lifecycle | 2,3 | committed-clean |
| 9 | `Smalt.Enclave.LifecycleTest` — OCEL stage emission fail-safe fence | 2,2,3 → 2,3 | committed-clean |
| 9b | `SmaltLroTest` — op records reach terminal at rest, zero polls, retention 500 (`test/lro_test.exs`) | 3 | committed-clean |
| 10 | `Smalt.PPlanTest` — lens7 half-degraded window Store down, `{:noproc,_}` typed | 2,3 | committed-checkable |
| 11 | `Smalt.AshExtension.Lens7FieldPolicyTest` — non-binary under :string projects nil | 2 | committed-clean |

## Classification vs `docs/jira/v26.10.17/FLAKE_LEDGER.md` + batch surfaces

- **No face matches ledger rows F1–F22.** F14/F18 (`store_churn :37`) did NOT
  recur (0/3); v1-soak's ErrorCodes doc-drift face did NOT recur (the regen
  landed — `docs/ERROR_CODES.md` was seen modified in the worktree mid-window
  and the face is absent from all three runs).
- **Deterministic 3/3 faces (NOT flakes — committed defects on the day's batch
  surfaces, repeatable in every run):**
  - `EnclaveStateTest` destroy residue (3/3) — enclave-state surface.
  - `Smalt.McpTest :420` / `Smalt.McpWireTest :806` doctor.summary missing
    `Smalt.Store` supervisor child (3/3 + 2/3) — one mechanism, two faces;
    supervisor children / table readiness surface.
  - These need an owner-lane fix, not ledger probation.
- **Rotating 2/3–1/3 faces (ledger-probation class, all unledgered):**
  TopologyTest ResourceWriteSuccess body, DetsRecovery engine-kill
  assert_eventually, EnclaveOcel + Enclave.Lifecycle (OCEL/lifecycle cluster,
  2/3), PPlan lens7, Lens7FieldPolicy, DSPy round-trip, LRO at-rest. All sit
  on NEW v26.10.18 batch surfaces (enclave/OCEL/pplan/azsim/dspy) that landed
  during this window — proposed new ledger rows pending owner-lane solo
  bisects. The enclave-lifecycle cluster face shows a possible shared-seed /
  shared-tree teardown signature (same mechanism family as F2/F8/F10), so a
  solo-bisect may collapse the cluster to one row.
- **Load-environment note (disclosure, not counted):** early attempts
  (17:50–19:35) were killed or compile-aborted: two SIGKILL (EXIT=137) under
  machine load 207–363 (external `yes` hogs + a VM), four compile aborts on
  in-flight `test/azsim/*.exs` lane edits (:113, :197, data_plane :72 x2,
  topology undefined `http_request/5`). Counted runs began 20:07 after load
  fell to 13–28. Compile-abort attempts: exit 1, 0 tests executed — recorded,
  not test failures.

## Standing

**SUSPECT.** 0/3 clean on the full suite — but the failure profile has
shifted from v1-soak's flake-class faces to deterministic 3/3 committed
defects on new enclave/MCP-doctor surfaces, plus a rotating unledgered
cluster on other batch surfaces. Wire court is 2/2 clean. The 0-failure
acceptance for the v2 rewrite is unmet; the deterministic 3/3 faces
(EnclaveState residue, doctor.summary/`Smalt.Store`) are the blocking set an
owning lane must take.

## Cleanup

`rm -rf /Users/sac/smalt/_build-ft-v2` was DENIED by the permission system.
**BLOCKED: `/Users/sac/smalt/_build-ft-v2` (343 MB) remains on disk** —
coordinator reclaim at integration (`just lane-clean` does not register this
root; direct removal needs coordinator authority).
