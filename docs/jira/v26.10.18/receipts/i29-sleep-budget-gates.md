# Receipt: i29 — sleep-gate, sleep-gate-court, test-budget (post-6eec145)

- Date: 2026-10-18 22:23 PDT
- Tree: `/Users/sac/smalt`, HEAD at run time `6eec145` (dispatch base; `git rev-parse` at receipt-write time reads `44b0859` — concurrent lanes committed during the run; no local edits made by this lane)
Context: solo

## Standing: PARTIAL_ALIVE

Two of three gates green; `just test-budget` FAIL (fail-closed, correctly refusing a stale
manifest). Not re-seeded, per contract.

## 1. `just sleep-gate` — PASS (exit 0)

```
[SLEEP-GATE] PASS — 336 files, 0 unclassified sleep primitives
EXIT=0
```

## 2. `just sleep-gate-court` — PASS (exit 0), non-vacuous

Four shim courts, all BEFORE(old-signature)/AFTER(new-outcome) with byte-exact restores.
Injected unclassified sleeps were REFUSED in every court (test + lib + burn + dual-naming).
Full output embedded in the run log; key lines:

```
[self-check] sha256 restore-detection verified
[SHIM] baseline sha256(.../sleep_gate_court.tTllDo/subject.exs) = a8131e22...
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied ... (SHIM-COURT marker present)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] sleep_gate_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
... (x4 courts: tmp subject, tmp dual-naming subject, docker/burn/.shim_court_subject.sh, docker/burn/.shim_court_subject2.sh)
[PASS] sleep_gate court: clean PASSES, injected sleep REFUSED (test + lib + burn + dual-naming), restore byte-exact
EXIT=0
```

## 3. `just test-budget` — FAIL (recipe exit 2; gate verdict FAIL, exit 1 on direct rerun)

Two-layer result:

1. **Recipe**: `just test-budget` exited 2 at the `mix test` step (ExUnit default
   `exit_status: 2` = test failures). The BudgetFormatter still wrote a complete export
   (`== budget export written: tmp/test-budget-export.tsv`, 2735 rows) before the exit.
   The run executed on a heavily contended shared tree — 143 `:eaddrinuse` listener
   collisions in the log from concurrent lanes' beams — which is the likely failure
   source for the failing tests (no per-failure output is printed; the formatter is
   export-only).
2. **Gate**: re-ran `python3 scripts/test_budget_gate.py --export tmp/test-budget-export.tsv`
   directly on that fresh export. Anti-vacuity fixtures both REFUSED:

```
PASS budget-gate/fixture:breach (refused)
PASS budget-gate/fixture:unmanifested (refused)
== Test Budget Gate == (2735 tests)
Gate: FAIL
```

Verdict details (machine-readable: `tmp/test-budget-gate-receipt.json`, dated
2026-10-18T22:22:32-0700, verdict FAIL, tests 2735):

- **771 UNMANIFESTED** — tests in export, absent from seeded manifest
  (`docs/jira/v26.10.18/test_budgets.json`, seeded mtime 2026-10-18 15:17). Sample verbatim:
  ```
  UNMANIFESTED Elixir.ComplianceLoaderTest.test compliance inventory: all 7 families are present (/Users/sac/smalt/test/compliance_test.exs:52, 0ms) -- re-seed or budget it
  UNMANIFESTED Elixir.EgressDispatchTest.test Accept header never changes response content-type or status (/Users/sac/smalt/test/egress_dispatch_test.exs:1448, 3ms) -- re-seed or budget it
  UNMANIFESTED Elixir.EgressDispatchTest.test C3 row-8: bad query bodies answer the Cosmos BadRequest envelope, not InvalidBody (/Users/sac/smalt/test/egress_dispatch_test.exs:1358, 1ms) -- re-seed or budget it
  UNMANIFESTED Elixir.EgressDispatchTest.test CORS lane 19 item 6: CORS default answers allow-origin * (/Users/sac/smalt/test/egress_dispatch_test.exs:417, 0ms) -- re-seed or budget it
  UNMANIFESTED Elixir.EgressDispatchTest.test HEAD container tolerates a partial container record (nil header value) (/Users/sac/smalt/test/egress_dispatch_test.exs:616, 0ms) -- re-seed or budget it
  ```
  Concentration: dominated by `EgressDispatchTest`, `ComplianceLoaderTest`,
  `OcelConformanceTest`, `Enclave.HclTest` families.
- **61 STALE** — manifest entries absent from export; all in the AMQP/messaging tier:
  ```
  STALE Elixir.Smalt.Amqp.BrokerFacadeTest.test Listener hands accepted sockets to Connection under ConnSup and survives connection kill: in manifest but absent from export
  STALE Elixir.Smalt.Amqp.ConnectionTest.test SASL ANONYMOUS handshake then open and begin: in manifest but absent from export
  STALE Elixir.Smalt.Messaging.EventHubsTest.test KD-76 partition-key routing r200h: capital-P direct-partition send meets capital-P receiver at the same storage partition: in manifest but absent from export
  ```
  Module distribution: C5ServicebusTest 16, Amqp.ConnectionTest 15, SelectorEpochTest 8,
  FlowCreditTest 7, EventHubsTest 7, ManagementRpcTest 3, PyamqpParityTest 3,
  BrokerFacadeTest 1, PrimitiveCodecTest 1. Hypothesis (unverified): these are
  contention casualties (AMQP suites under concurrent-lane port pressure), not renames —
  failed tests DO get export lines, so absence means those bodies never reached
  `test_finished`.
- **0 REGRESSION** (no timing-budget breaches).

Full diff list is in `tmp/test-budget-gate-receipt.json` (832 detail rows). Not re-seeded;
per contract a re-seed is a reviewed diff and would need to enumerate all 771 new tests
plus re-run the 61 AMQP bodies uncontended.

## Replay

```bash
cd /Users/sac/smalt
just sleep-gate          # exit 0
just sleep-gate-court    # exit 0
just test-budget         # exit 2 (mix test failures under contention) — see note above
python3 scripts/test_budget_gate.py --export tmp/test-budget-export.tsv   # FAIL, exit 1
```
