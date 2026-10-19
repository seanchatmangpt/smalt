# i28 — azsim regression court (full set, current tree)

Standing: **SUSPECT** (2 NEW deterministic failures, unregistered anywhere)

Date: 2026-10-18 · Build root: `_build-ft-azr` · No edits, no git.

## Commands + output

```
$ MIX_BUILD_ROOT=_build-ft-azr mix test test/azsim/
73 tests, 2 failures (3 excluded)
```

12 files present in `test/azsim/` (10 active + `amqp_saturation_test.exs`
which is 0 tests / 3 excluded — wire tier off by default).

### Transient compile abort (resolved mid-session, disclosed)

First batch run aborted:

```
== Compilation error in file lib/smalt/plane/identity/sts_gate.ex ==
** (SyntaxError) invalid syntax found on lib/smalt/plane/identity/sts_gate.ex:39:10:
    error: unexpected operator -> ... Syntax error before: '->'
 39 |     unit -> true
```

`lib/smalt/plane/identity/sts_gate.ex` was mid-edit by another lane (git
status `M`). Repaired by its owner mid-session per the compile-freeze SLA
(file now compiles: `mix compile` → `Generated smalt app`). Disclosed here;
the fix belongs to that lane's receipt.

## Solo runs (each file individually)

| File | Solo result |
|---|---|
| adversarial_joe_test.exs | 4 tests, 0 failures |
| amqp_saturation_test.exs | 0 tests (3 excluded) |
| azure_common_issues_test.exs | 6 tests, **2 failures** |
| control_plane_test.exs | 12 tests, 0 failures |
| data_plane_test.exs | 8 tests, 0 failures |
| dets_recovery_test.exs | 5 tests, 0 failures |
| dr_scenarios_test.exs | 4 tests, 0 failures |
| graceful_stop_test.exs | 3 tests, 0 failures |
| identity_plane_test.exs | 12 tests, 0 failures |
| integration_plane_test.exs | 9 tests, 0 failures |
| plane_supervision_test.exs | 2 tests, 0 failures |
| topology_test.exs | 8 tests, 0 failures |

Solo totals mirror the batch: the 2 failures are deterministic, not
load-rotating.

## Failure classification: NEW, not KNOWN-IN-REPAIR

The known deterministic pair in the i27 bisect receipt
(`docs/jira/v26.10.18/receipts/i27-rotating-bisect.md`) is
`test/enclave_ocel_test.exs` (`ORPHANED_DATA_PLANE_ROWS_DETECTED`) — not
involved here. Neither failing test is registered in
`docs/jira/v26.10.18/test_budgets.json` (`AzureCommonIssuesTest` absent from
that file entirely). Both fail identically solo and in batch.

**Failure 1** — `Smalt.Azsim.AzureCommonIssuesTest` Vector 1:
`test/azsim/azure_common_issues_test.exs:59`

```
concurrent updates against a single ETag yield exactly 1 winner and N 412 PreconditionFailed
Expected exactly 1 winner, got 0
code: assert length(winners) == 1, "Expected exactly 1 winner, got #{length(winners)}"
test/azsim/azure_common_issues_test.exs:94
```

**Failure 2** — Vector 6, malformed CloudEvent refusal:
`test/azsim/azure_common_issues_test.exs:236`

```
Assertion with in failed
assert conn.status in [400, 401, 403]
left:  404
right: [400, 401, 403]
test/azsim/azure_common_issues_test.exs:253
```

### Provenance

`azure_common_issues_test.exs` landed in commit `710c5e1` ("feat(azsim):
AZB-19 overlap court + AZB-22 ring + rotating bisect collapse"), which is an
ancestor of current HEAD. The `azb-19-overlap.md` receipt does not register
either failure as accepted/known. Vector 1 (0 winners instead of 1 —
cosmos-style ETag CAS losing ALL concurrent writers) and Vector 6 (404 instead
of a 4xx validation refusal — route/table not present) look like real surface
gaps, not test-harness noise, but I made no repairs.

Machine: Apple M3 Max, macOS 26.2.
